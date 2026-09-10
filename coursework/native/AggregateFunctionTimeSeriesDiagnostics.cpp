#include <AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesDiagnostics.h>

#include <AggregateFunctions/AggregateFunctionFactory.h>
#include <AggregateFunctions/FactoryHelpers.h>
#include <AggregateFunctions/IAggregateFunction.h>
#include <Columns/ColumnDecimal.h>
#include <Columns/ColumnTuple.h>
#include <Columns/ColumnsNumber.h>
#include <Core/Settings.h>
#include <DataTypes/DataTypeTuple.h>
#include <DataTypes/DataTypesDecimal.h>
#include <DataTypes/DataTypesNumber.h>
#include <Common/assert_cast.h>

#include <boost/math/distributions/chi_squared.hpp>

#include <cmath>
#include <utility>

namespace DB
{

namespace ErrorCodes
{
extern const int BAD_ARGUMENTS;
extern const int ILLEGAL_TYPE_OF_ARGUMENT;
extern const int NUMBER_OF_ARGUMENTS_DOESNT_MATCH;
extern const int UNKNOWN_AGGREGATE_FUNCTION;
}

namespace Setting
{
extern const SettingsBool enable_time_series_aggregate_functions;
extern const SettingsBool enable_time_series_table;
}

namespace
{

enum class ResultKind : UInt8
{
    Autocorrelation,
    LjungBoxTest,
    DurbinWatson,
};

struct FunctionSpec
{
    ResultKind kind = ResultKind::Autocorrelation;
    UInt64 lag = 0;
    UInt64 model_df = 0;
    UInt64 max_samples = TimeSeriesDiagnostics::DEFAULT_MAX_SAMPLES;
};

DataTypePtr resultType(ResultKind kind)
{
    if (kind == ResultKind::LjungBoxTest)
    {
        return std::make_shared<DataTypeTuple>(
            DataTypes{std::make_shared<DataTypeFloat64>(), std::make_shared<DataTypeFloat64>()}, Names{"statistic", "p_value"});
    }
    return std::make_shared<DataTypeFloat64>();
}

UInt64 unsignedParameter(const String & name, const Field & parameter, const String & parameter_name)
{
    if (UInt64 value = 0; parameter.tryGet(value))
        return value;
    if (Int64 value = 0; parameter.tryGet(value))
    {
        if (value >= 0)
            return static_cast<UInt64>(value);
    }
    throw Exception(
        ErrorCodes::BAD_ARGUMENTS, "Parameter {} of aggregate function {} must be a non-negative integer", parameter_name, name);
}

UInt64 positiveParameter(const String & name, const Field & parameter, const String & parameter_name)
{
    const UInt64 value = unsignedParameter(name, parameter, parameter_name);
    if (!value)
        throw Exception(ErrorCodes::BAD_ARGUMENTS, "Parameter {} of aggregate function {} must be positive", parameter_name, name);
    return value;
}

void validateMaxSamples(const String & name, UInt64 max_samples)
{
    if (!max_samples || max_samples > TimeSeriesDiagnostics::HARD_MAX_SAMPLES)
        throw Exception(
            ErrorCodes::BAD_ARGUMENTS,
            "Parameter max_samples of aggregate function {} must be in [1, {}], got {}",
            name,
            TimeSeriesDiagnostics::HARD_MAX_SAMPLES,
            max_samples);
}

FunctionSpec parseSpec(const String & name, const Array & parameters)
{
    FunctionSpec spec;
    if (name == "timeSeriesAutocorrelation")
    {
        if (parameters.size() < 1 || parameters.size() > 2)
            throw Exception(ErrorCodes::NUMBER_OF_ARGUMENTS_DOESNT_MATCH, "Aggregate function {} requires lag[, max_samples]", name);
        spec.kind = ResultKind::Autocorrelation;
        spec.lag = unsignedParameter(name, parameters[0], "lag");
        if (parameters.size() == 2)
            spec.max_samples = positiveParameter(name, parameters[1], "max_samples");
    }
    else if (name == "timeSeriesLjungBoxTest")
    {
        if (parameters.empty() || parameters.size() > 3)
            throw Exception(
                ErrorCodes::NUMBER_OF_ARGUMENTS_DOESNT_MATCH, "Aggregate function {} requires max_lag[, model_df[, max_samples]]", name);
        spec.kind = ResultKind::LjungBoxTest;
        spec.lag = positiveParameter(name, parameters[0], "max_lag");
        if (parameters.size() >= 2)
            spec.model_df = unsignedParameter(name, parameters[1], "model_df");
        if (parameters.size() == 3)
            spec.max_samples = positiveParameter(name, parameters[2], "max_samples");
        if (spec.model_df >= spec.lag)
            throw Exception(
                ErrorCodes::BAD_ARGUMENTS,
                "Parameter model_df ({}) must be less than max_lag ({}) for aggregate function {}",
                spec.model_df,
                spec.lag,
                name);
    }
    else if (name == "timeSeriesDurbinWatson")
    {
        if (parameters.size() > 1)
            throw Exception(ErrorCodes::NUMBER_OF_ARGUMENTS_DOESNT_MATCH, "Aggregate function {} accepts only [max_samples]", name);
        spec.kind = ResultKind::DurbinWatson;
        if (!parameters.empty())
            spec.max_samples = positiveParameter(name, parameters[0], "max_samples");
    }
    else
    {
        throw Exception(ErrorCodes::BAD_ARGUMENTS, "Unknown time-series diagnostic function {}", name);
    }

    validateMaxSamples(name, spec.max_samples);
    if (spec.lag > TimeSeriesDiagnostics::HARD_MAX_LAG)
        throw Exception(
            ErrorCodes::BAD_ARGUMENTS,
            "Lag {} exceeds hard limit {} for aggregate function {}",
            spec.lag,
            TimeSeriesDiagnostics::HARD_MAX_LAG,
            name);
    if (spec.lag && spec.lag >= spec.max_samples)
        throw Exception(
            ErrorCodes::BAD_ARGUMENTS,
            "Lag {} must be less than max_samples={} for aggregate function {}",
            spec.lag,
            spec.max_samples,
            name);
    return spec;
}

template <typename Timestamp>
class AggregateFunctionTimeSeriesDiagnostics final
    : public IAggregateFunctionDataHelper<TimeSeriesDiagnostics::State<Timestamp>, AggregateFunctionTimeSeriesDiagnostics<Timestamp>>
{
    using State = TimeSeriesDiagnostics::State<Timestamp>;
    using Base = IAggregateFunctionDataHelper<State, AggregateFunctionTimeSeriesDiagnostics<Timestamp>>;
    using TimestampColumn = ColumnVectorOrDecimal<Timestamp>;

public:
    AggregateFunctionTimeSeriesDiagnostics(String name_, FunctionSpec spec_, const DataTypes & arguments, const Array & parameters_)
        : Base(arguments, parameters_, resultType(spec_.kind))
        , name(std::move(name_))
        , spec(spec_)
    {
    }

    String getName() const override { return name; }
    bool allocatesMemoryInArena() const override { return false; }

    void add(AggregateDataPtr __restrict place, const IColumn ** columns, size_t row_num, Arena *) const override
    {
        const auto & timestamp_column = assert_cast<const TimestampColumn &>(*columns[0]);
        this->data(place).add(timestamp_column.getData()[row_num], columns[1]->getFloat64(row_num), spec.max_samples);
    }

    void mergeImpl(AggregateDataPtr __restrict place, ConstAggregateDataPtr rhs, Arena *) const override
    {
        this->data(place).merge(this->data(rhs), spec.max_samples);
    }

    void serialize(ConstAggregateDataPtr __restrict place, WriteBuffer & buffer, std::optional<size_t>) const override
    {
        this->data(place).serialize(buffer, spec.max_samples);
    }

    void deserialize(AggregateDataPtr __restrict place, ReadBuffer & buffer, std::optional<size_t>, Arena *) const override
    {
        this->data(place).deserialize(buffer, spec.max_samples);
    }

    void insertResultInto(AggregateDataPtr __restrict place, IColumn & to, Arena *) const override
    {
        State & state = this->data(place);
        if (spec.kind == ResultKind::Autocorrelation)
        {
            assert_cast<ColumnFloat64 &>(to).getData().push_back(state.autocorrelation(spec.lag));
            return;
        }
        if (spec.kind == ResultKind::DurbinWatson)
        {
            assert_cast<ColumnFloat64 &>(to).getData().push_back(state.durbinWatson());
            return;
        }

        const Float64 statistic = state.ljungBoxStatistic(spec.lag);
        Float64 p_value = std::numeric_limits<Float64>::quiet_NaN();
        if (!std::isnan(statistic))
        {
            const Float64 degrees_of_freedom = static_cast<Float64>(spec.lag - spec.model_df);
            const boost::math::chi_squared_distribution<Float64> distribution(degrees_of_freedom);
            p_value = boost::math::cdf(boost::math::complement(distribution, statistic));
        }

        auto & tuple = assert_cast<ColumnTuple &>(to);
        assert_cast<ColumnFloat64 &>(tuple.getColumn(0)).getData().push_back(statistic);
        assert_cast<ColumnFloat64 &>(tuple.getColumn(1)).getData().push_back(p_value);
    }

private:
    String name;
    FunctionSpec spec;
};

AggregateFunctionPtr createAggregateFunctionTimeSeriesDiagnostics(
    const String & name, const DataTypes & arguments, const Array & parameters, const Settings * settings)
{
    if (settings && (*settings)[Setting::enable_time_series_aggregate_functions] == 0
        && (*settings)[Setting::enable_time_series_table] == 0)
        throw Exception(
            ErrorCodes::UNKNOWN_AGGREGATE_FUNCTION,
            "Aggregate function {} is in private preview and disabled by default. "
            "Enable it with setting enable_time_series_aggregate_functions",
            name);

    assertBinary(name, arguments);
    const FunctionSpec spec = parseSpec(name, parameters);
    const DataTypePtr & timestamp_type = arguments[0];
    const DataTypePtr & value_type = arguments[1];
    if (!isNativeNumber(value_type))
        throw Exception(
            ErrorCodes::ILLEGAL_TYPE_OF_ARGUMENT,
            "Illegal value type {} for aggregate function {}, expected a native numeric type",
            value_type->getName(),
            name);

    if (isDateTime64(timestamp_type))
        return std::make_shared<AggregateFunctionTimeSeriesDiagnostics<DateTime64>>(name, spec, arguments, parameters);
    if (isDateTime(timestamp_type) || isUInt32(timestamp_type))
        return std::make_shared<AggregateFunctionTimeSeriesDiagnostics<UInt32>>(name, spec, arguments, parameters);
    if (isUInt64(timestamp_type))
        return std::make_shared<AggregateFunctionTimeSeriesDiagnostics<UInt64>>(name, spec, arguments, parameters);

    throw Exception(
        ErrorCodes::ILLEGAL_TYPE_OF_ARGUMENT,
        "Illegal timestamp type {} for aggregate function {}, expected UInt32, UInt64, DateTime, or DateTime64",
        timestamp_type->getName(),
        name);
}

}

void registerAggregateFunctionsTimeSeriesDiagnostics(AggregateFunctionFactory &);
void registerAggregateFunctionsTimeSeriesDiagnostics(AggregateFunctionFactory & factory)
{
    AggregateFunctionProperties properties;

    const FunctionDocumentation::Arguments common_arguments = {
        {"timestamp", "Unique ordering key for the sample. Gaps between keys are ignored.", {"UInt32", "UInt64", "DateTime", "DateTime64"}},
        {"value", "Finite time-series or residual value. Rows where either argument is NULL are skipped.", {"(U)Int*", "Float*"}},
    };
    const FunctionDocumentation::IntroducedIn introduced_in = {26, 9};
    const auto category = FunctionDocumentation::Category::AggregateFunction;

    FunctionDocumentation autocorrelation_documentation = {
        .description = R"(
Calculates autocorrelation after sorting samples by their unique timestamp.
For lag k, the numerator is the sum of centered products k samples apart and the denominator is the centered sum of squares over the full series. Lag zero returns 1 for a non-constant series.

Duplicate timestamps and non-finite values cause an exception. Undefined results are NaN. The state retains all samples, so memory consumption is O(n) up to max_samples.

:::note
This function is in private preview. Enable it with setting `enable_time_series_aggregate_functions`.
:::)",
        .syntax = "timeSeriesAutocorrelation(lag[, max_samples])(timestamp, value)",
        .arguments = common_arguments,
        .parameters = {
            {"lag", "Non-negative lag in samples.", {"UInt64"}},
            {"max_samples", "Optional positive state-size cap. Default: 1000000.", {"UInt64"}},
        },
        .returned_value = {"Returns the sample-mean-centered autocorrelation.", {"Float64"}},
        .examples = {{
            "Lag-one autocorrelation",
            R"(
SET enable_time_series_aggregate_functions = 1;
SELECT round(timeSeriesAutocorrelation(1)(timestamp, value), 6) AS acf
FROM values('timestamp UInt64, value Float64', (4, 5.), (1, 2.), (3, 4.), (0, 1.), (2, 3.));
            )",
            "0.4"}},
        .introduced_in = introduced_in,
        .category = category,
    };

    FunctionDocumentation ljung_box_documentation = {
        .description = R"(
Runs the Ljung-Box portmanteau test after sorting samples by their unique timestamp.
The statistic is Q = n(n + 2) * sum(rho_k^2 / (n - k)) for k from 1 through max_lag. The returned p-value is the chi-squared survival probability with max_lag - model_df degrees of freedom.

Duplicate timestamps and non-finite values cause an exception. Undefined results are returned as a tuple of NaNs. The state retains all samples, so memory consumption is O(n) up to max_samples and finalization costs O(n * max_lag).

:::note
This function is in private preview. Enable it with setting `enable_time_series_aggregate_functions`.
:::)",
        .syntax = "timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])(timestamp, value)",
        .arguments = common_arguments,
        .parameters = {
            {"max_lag", "Positive largest lag included in the statistic.", {"UInt64"}},
            {"model_df", "Optional fitted-model degrees of freedom subtracted from max_lag. Default: 0.", {"UInt64"}},
            {"max_samples", "Optional positive state-size cap. Default: 1000000.", {"UInt64"}},
        },
        .returned_value = {
            "Returns a named tuple (statistic, p_value).",
            {"Tuple(statistic Float64, p_value Float64)"}},
        .examples = {{
            "Test a short series",
            R"(
SET enable_time_series_aggregate_functions = 1;
SELECT
    round(test.statistic, 6) AS statistic,
    round(test.p_value, 6) AS p_value
FROM
(
    SELECT timeSeriesLjungBoxTest(2)(timestamp, value) AS test
    FROM values('timestamp UInt64, value Float64', (4, 5.), (1, 2.), (3, 4.), (0, 1.), (2, 3.))
);
            )",
            "1.516667\t0.468447"}},
        .introduced_in = introduced_in,
        .category = category,
    };

    FunctionDocumentation durbin_watson_documentation = {
        .description = R"(
Calculates the Durbin-Watson statistic after sorting residual samples by their unique timestamp.
It divides the sum of squared differences between consecutive residuals by the sum of squared residuals. Timestamp spacing is ignored.

Duplicate timestamps and non-finite values cause an exception. Undefined results are NaN. The state retains all samples, so memory consumption is O(n) up to max_samples.

:::note
This function is in private preview. Enable it with setting `enable_time_series_aggregate_functions`.
:::)",
        .syntax = "timeSeriesDurbinWatson([max_samples])(timestamp, value)",
        .arguments = common_arguments,
        .parameters = {
            {"max_samples", "Optional positive state-size cap. Default: 1000000.", {"UInt64"}},
        },
        .returned_value = {"Returns the Durbin-Watson statistic.", {"Float64"}},
        .examples = {{
            "Residual diagnostic",
            R"(
SET enable_time_series_aggregate_functions = 1;
SELECT round(timeSeriesDurbinWatson()(timestamp, residual), 6) AS statistic
FROM values('timestamp UInt64, residual Float64', (4, 4.), (1, 1.), (3, 3.), (2, 2.));
            )",
            "0.1"}},
        .introduced_in = introduced_in,
        .category = category,
    };

    factory.registerFunction(
        "timeSeriesAutocorrelation", {createAggregateFunctionTimeSeriesDiagnostics, autocorrelation_documentation, properties});
    factory.registerFunction("timeSeriesLjungBoxTest", {createAggregateFunctionTimeSeriesDiagnostics, ljung_box_documentation, properties});
    factory.registerFunction(
        "timeSeriesDurbinWatson", {createAggregateFunctionTimeSeriesDiagnostics, durbin_watson_documentation, properties});
}

}
