#include <AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.h>

#include <AggregateFunctions/AggregateFunctionFactory.h>
#include <AggregateFunctions/FactoryHelpers.h>
#include <AggregateFunctions/IAggregateFunction.h>
#include <Columns/ColumnArray.h>
#include <Columns/ColumnDecimal.h>
#include <Columns/ColumnTuple.h>
#include <Columns/ColumnsNumber.h>
#include <Core/Settings.h>
#include <DataTypes/DataTypeArray.h>
#include <DataTypes/DataTypeTuple.h>
#include <DataTypes/DataTypesDecimal.h>
#include <DataTypes/DataTypesNumber.h>
#include <Common/assert_cast.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <numeric>
#include <utility>
#include <vector>

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

using namespace TimeSeriesStatisticalExtensions;

constexpr UInt64 HARD_MAX_ORDER = 16;
constexpr UInt64 HARD_MAX_KPSS_BANDWIDTH = 1024;
constexpr UInt64 HARD_MAX_KPSS_WORK = 100'000'000;
constexpr UInt64 HARD_MAX_REGRESSION_QR_WORK = 100'000'000;
constexpr UInt64 DEFAULT_BANDWIDTH = std::numeric_limits<UInt64>::max();
constexpr size_t MAX_REGRESSION_COLUMNS = 20;

enum class ADFDeterministic : UInt8
{
    None = 0,
    Constant = 1,
    Trend = 2
};
enum class KPSSRegression : UInt8
{
    Level = 0,
    Trend = 1
};

struct Spec
{
    Kind kind{};
    UInt64 first = 0;
    UInt64 second = 0;
    UInt64 max_samples = TimeSeriesDiagnostics::DEFAULT_MAX_SAMPLES;

    Parameters stateParameters() const
    {
        return Parameters{.kind = kind, .first = first, .second = second, .third = 0, .max_samples = max_samples};
    }
};

Float64 nan()
{
    return std::numeric_limits<Float64>::quiet_NaN();
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

String stringParameter(const String & name, const Field & parameter, const String & parameter_name)
{
    String value;
    if (!parameter.tryGet(value))
        throw Exception(ErrorCodes::BAD_ARGUMENTS, "Parameter {} of aggregate function {} must be a string", parameter_name, name);
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

void validateOrder(const String & name, UInt64 order, UInt64 max_samples, const String & parameter_name)
{
    if (!order || order > HARD_MAX_ORDER)
        throw Exception(
            ErrorCodes::BAD_ARGUMENTS, "Parameter {} of aggregate function {} must be in [1, {}]", parameter_name, name, HARD_MAX_ORDER);
    if (order >= max_samples)
        throw Exception(
            ErrorCodes::BAD_ARGUMENTS, "Parameter {} must be less than max_samples for aggregate function {}", parameter_name, name);
}

Spec parseSpec(const String & name, const Array & parameters)
{
    Spec spec;
    if (name == "timeSeriesLaggedLinearRegression")
    {
        if (parameters.empty() || parameters.size() > 2)
            throw Exception(ErrorCodes::NUMBER_OF_ARGUMENTS_DOESNT_MATCH, "Aggregate function {} requires order[, max_samples]", name);
        spec.kind = Kind::LaggedLinearRegression;
        spec.first = positiveParameter(name, parameters[0], "order");
        if (parameters.size() == 2)
            spec.max_samples = positiveParameter(name, parameters[1], "max_samples");
        validateMaxSamples(name, spec.max_samples);
        validateOrder(name, spec.first, spec.max_samples, "order");
        return spec;
    }

    if (name == "timeSeriesADFStatistic")
    {
        if (parameters.empty() || parameters.size() > 3)
            throw Exception(
                ErrorCodes::NUMBER_OF_ARGUMENTS_DOESNT_MATCH,
                "Aggregate function {} requires augmentation_lags[, deterministic[, max_samples]]",
                name);
        spec.kind = Kind::ADFStatistic;
        spec.first = unsignedParameter(name, parameters[0], "augmentation_lags");
        if (spec.first > HARD_MAX_ORDER)
            throw Exception(
                ErrorCodes::BAD_ARGUMENTS, "augmentation_lags of aggregate function {} must not exceed {}", name, HARD_MAX_ORDER);
        spec.second = static_cast<UInt64>(ADFDeterministic::Constant);
        if (parameters.size() >= 2)
        {
            const String deterministic = stringParameter(name, parameters[1], "deterministic");
            if (deterministic == "none")
                spec.second = static_cast<UInt64>(ADFDeterministic::None);
            else if (deterministic == "constant")
                spec.second = static_cast<UInt64>(ADFDeterministic::Constant);
            else if (deterministic == "trend")
                spec.second = static_cast<UInt64>(ADFDeterministic::Trend);
            else
                throw Exception(ErrorCodes::BAD_ARGUMENTS, "deterministic of aggregate function {} must be none, constant, or trend", name);
        }
        if (parameters.size() == 3)
            spec.max_samples = positiveParameter(name, parameters[2], "max_samples");
        validateMaxSamples(name, spec.max_samples);
        if (spec.first >= spec.max_samples)
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "augmentation_lags must be less than max_samples for aggregate function {}", name);
        return spec;
    }

    if (name == "timeSeriesKPSSTest")
    {
        if (parameters.empty() || parameters.size() > 3)
            throw Exception(
                ErrorCodes::NUMBER_OF_ARGUMENTS_DOESNT_MATCH,
                "Aggregate function {} requires regression[, bandwidth[, max_samples]]",
                name);
        spec.kind = Kind::KPSSTest;
        const String regression = stringParameter(name, parameters[0], "regression");
        if (regression == "level")
            spec.first = static_cast<UInt64>(KPSSRegression::Level);
        else if (regression == "trend")
            spec.first = static_cast<UInt64>(KPSSRegression::Trend);
        else
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "regression of aggregate function {} must be level or trend", name);
        spec.second = DEFAULT_BANDWIDTH;
        if (parameters.size() >= 2)
        {
            spec.second = unsignedParameter(name, parameters[1], "bandwidth");
            if (spec.second > HARD_MAX_KPSS_BANDWIDTH)
                throw Exception(
                    ErrorCodes::BAD_ARGUMENTS, "bandwidth of aggregate function {} must not exceed {}", name, HARD_MAX_KPSS_BANDWIDTH);
        }
        if (parameters.size() == 3)
            spec.max_samples = positiveParameter(name, parameters[2], "max_samples");
        validateMaxSamples(name, spec.max_samples);
        if (parameters.size() >= 2 && spec.second >= spec.max_samples)
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "bandwidth must be less than max_samples for aggregate function {}", name);
        return spec;
    }

    if (name == "timeSeriesMeanShiftChangePoint")
    {
        if (parameters.empty() || parameters.size() > 2)
            throw Exception(
                ErrorCodes::NUMBER_OF_ARGUMENTS_DOESNT_MATCH, "Aggregate function {} requires min_segment[, max_samples]", name);
        spec.kind = Kind::MeanShiftChangePoint;
        spec.first = positiveParameter(name, parameters[0], "min_segment");
        if (parameters.size() == 2)
            spec.max_samples = positiveParameter(name, parameters[1], "max_samples");
        validateMaxSamples(name, spec.max_samples);
        if (spec.first > spec.max_samples / 2)
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "min_segment must not exceed max_samples / 2 for aggregate function {}", name);
        return spec;
    }

    throw Exception(ErrorCodes::BAD_ARGUMENTS, "Unknown time-series statistical extension {}", name);
}

DataTypePtr resultType(const Spec & spec)
{
    const auto f64 = std::make_shared<DataTypeFloat64>();
    const auto u64 = std::make_shared<DataTypeUInt64>();
    if (spec.kind == Kind::LaggedLinearRegression)
        return std::make_shared<DataTypeTuple>(DataTypes{f64, std::make_shared<DataTypeArray>(f64)}, Names{"intercept", "coefficients"});
    if (spec.kind == Kind::ADFStatistic)
        return std::make_shared<DataTypeTuple>(DataTypes{f64, f64, u64}, Names{"statistic", "coefficient", "observations"});
    if (spec.kind == Kind::KPSSTest)
        return std::make_shared<DataTypeTuple>(DataTypes{f64, u64, u64}, Names{"statistic", "bandwidth", "observations"});
    return std::make_shared<DataTypeTuple>(
        DataTypes{u64, f64, f64, f64, f64}, Names{"split_index", "score", "mean_before", "mean_after", "sse"});
}

struct Transform
{
    Float64 location = 0;
    Float64 scale = 0;
    Float64 mean_scaled = 0;
};

struct LeastSquaresResult
{
    bool valid = false;
    bool residual_is_below_resolution = false;
    std::vector<Float64> beta;
    std::vector<Float64> inverse_diagonal;
    Float64 residual_sse = nan();
    Transform response;
    std::vector<Transform> predictors;
};

/// A streaming Givens QR factorization. It is deliberately self-contained:
/// ClickHouse does not require a generic BLAS/LAPACK dependency for this small,
/// bounded (at most 18-column) solve.
class GivensQR
{
public:
    explicit GivensQR(size_t columns_)
        : columns(columns_)
        , r(columns * columns, 0)
        , qty(columns, 0)
    {
    }

    void add(const std::array<Float64, MAX_REGRESSION_COLUMNS> & input, Float64 response)
    {
        std::array<Float64, MAX_REGRESSION_COLUMNS> row = input;
        Float64 rhs = response;
        for (size_t j = 0; j < columns; ++j)
        {
            const Float64 diagonal = r[j * columns + j];
            const Float64 magnitude = std::hypot(diagonal, row[j]);
            if (magnitude == 0)
                continue;
            const Float64 c = diagonal / magnitude;
            const Float64 s = row[j] / magnitude;
            for (size_t k = j; k < columns; ++k)
            {
                const Float64 old_r = r[j * columns + k];
                const Float64 old_row = row[k];
                r[j * columns + k] = c * old_r + s * old_row;
                row[k] = -s * old_r + c * old_row;
            }
            const Float64 old_rhs = qty[j];
            qty[j] = c * old_rhs + s * rhs;
            rhs = -s * old_rhs + c * rhs;
        }
        residual.add(rhs * rhs);
    }

    bool solve(std::vector<Float64> & beta, std::vector<Float64> & inverse_diagonal, Float64 & residual_sse) const
    {
        Float64 norm_r = 0;
        for (size_t i = 0; i < columns; ++i)
        {
            Float64 row_sum = 0;
            for (size_t j = i; j < columns; ++j)
                row_sum += std::abs(r[i * columns + j]);
            norm_r = std::max(norm_r, row_sum);
        }
        if (!(norm_r > 0) || !std::isfinite(norm_r))
            return false;

        std::vector<Float64> inverse(columns * columns, 0);
        for (size_t rhs = 0; rhs < columns; ++rhs)
        {
            for (size_t ii = columns; ii-- > 0;)
            {
                Float64 value = ii == rhs ? 1. : 0.;
                for (size_t j = ii + 1; j < columns; ++j)
                    value -= r[ii * columns + j] * inverse[j * columns + rhs];
                const Float64 diagonal = r[ii * columns + ii];
                if (!(std::abs(diagonal) > 0) || !std::isfinite(diagonal))
                    return false;
                inverse[ii * columns + rhs] = value / diagonal;
            }
        }

        Float64 norm_inverse = 0;
        for (size_t i = 0; i < columns; ++i)
        {
            Float64 row_sum = 0;
            for (size_t j = 0; j < columns; ++j)
                row_sum += std::abs(inverse[i * columns + j]);
            norm_inverse = std::max(norm_inverse, row_sum);
        }
        const Float64 reciprocal_condition = 1. / (norm_r * norm_inverse);
        if (!(reciprocal_condition >= 1e-12) || !std::isfinite(reciprocal_condition))
            return false;

        beta.assign(columns, 0);
        for (size_t ii = columns; ii-- > 0;)
        {
            Float64 value = qty[ii];
            for (size_t j = ii + 1; j < columns; ++j)
                value -= r[ii * columns + j] * beta[j];
            beta[ii] = value / r[ii * columns + ii];
            if (!std::isfinite(beta[ii]))
                return false;
        }

        inverse_diagonal.assign(columns, 0);
        for (size_t i = 0; i < columns; ++i)
        {
            TimeSeriesDiagnostics::CompensatedSum sum;
            for (size_t j = 0; j < columns; ++j)
                sum.add(inverse[i * columns + j] * inverse[i * columns + j]);
            inverse_diagonal[i] = sum.result();
        }
        residual_sse = residual.result();
        return std::isfinite(residual_sse);
    }

private:
    size_t columns;
    std::vector<Float64> r;
    std::vector<Float64> qty;
    TimeSeriesDiagnostics::CompensatedSum residual;
};

template <typename RowBuilder>
LeastSquaresResult fitLeastSquares(size_t rows, size_t columns, bool center, RowBuilder && build)
{
    LeastSquaresResult result;
    if (!rows || !columns || columns > MAX_REGRESSION_COLUMNS || rows <= columns)
        return result;
    const UInt64 work_per_row = static_cast<UInt64>(columns) * static_cast<UInt64>(columns);
    if (static_cast<UInt64>(rows) > HARD_MAX_REGRESSION_QR_WORK / work_per_row)
        return result;

    std::array<Float64, MAX_REGRESSION_COLUMNS> minimum{};
    std::array<Float64, MAX_REGRESSION_COLUMNS> maximum{};
    minimum.fill(std::numeric_limits<Float64>::infinity());
    maximum.fill(-std::numeric_limits<Float64>::infinity());
    Float64 response_minimum = std::numeric_limits<Float64>::infinity();
    Float64 response_maximum = -std::numeric_limits<Float64>::infinity();

    for (size_t i = 0; i < rows; ++i)
    {
        std::array<Float64, MAX_REGRESSION_COLUMNS> row{};
        Float64 response = 0;
        build(i, row, response);
        if (!std::isfinite(response))
            return result;
        response_minimum = std::min(response_minimum, response);
        response_maximum = std::max(response_maximum, response);
        for (size_t j = 0; j < columns; ++j)
        {
            if (!std::isfinite(row[j]))
                return result;
            minimum[j] = std::min(minimum[j], row[j]);
            maximum[j] = std::max(maximum[j], row[j]);
        }
    }

    auto make_transform = [center](Float64 minimum_value, Float64 maximum_value)
    {
        Transform transform;
        if (center)
        {
            transform.location = std::midpoint(minimum_value, maximum_value);
            transform.scale = std::max(std::abs(minimum_value - transform.location), std::abs(maximum_value - transform.location));
        }
        else
        {
            transform.scale = std::max(std::abs(minimum_value), std::abs(maximum_value));
        }
        return transform;
    };

    result.predictors.resize(columns);
    for (size_t j = 0; j < columns; ++j)
    {
        result.predictors[j] = make_transform(minimum[j], maximum[j]);
        if (!(result.predictors[j].scale > 0) || !std::isfinite(result.predictors[j].scale))
            return LeastSquaresResult{};
    }
    result.response = make_transform(response_minimum, response_maximum);
    if (!(result.response.scale > 0) || !std::isfinite(result.response.scale))
        return LeastSquaresResult{};

    if (center)
    {
        std::array<TimeSeriesDiagnostics::CompensatedSum, MAX_REGRESSION_COLUMNS> sums;
        TimeSeriesDiagnostics::CompensatedSum response_sum;
        for (size_t i = 0; i < rows; ++i)
        {
            std::array<Float64, MAX_REGRESSION_COLUMNS> row{};
            Float64 response = 0;
            build(i, row, response);
            response_sum.add((response - result.response.location) / result.response.scale);
            for (size_t j = 0; j < columns; ++j)
                sums[j].add((row[j] - result.predictors[j].location) / result.predictors[j].scale);
        }
        result.response.mean_scaled = response_sum.result() / static_cast<Float64>(rows);
        for (size_t j = 0; j < columns; ++j)
            result.predictors[j].mean_scaled = sums[j].result() / static_cast<Float64>(rows);
    }

    GivensQR qr(columns);
    TimeSeriesDiagnostics::CompensatedSum response_sum_squares;
    TimeSeriesDiagnostics::CompensatedSum design_sum_squares;
    for (size_t i = 0; i < rows; ++i)
    {
        std::array<Float64, MAX_REGRESSION_COLUMNS> row{};
        Float64 response = 0;
        build(i, row, response);
        for (size_t j = 0; j < columns; ++j)
        {
            row[j] = (row[j] - result.predictors[j].location) / result.predictors[j].scale - result.predictors[j].mean_scaled;
            design_sum_squares.add(row[j] * row[j]);
        }
        response = (response - result.response.location) / result.response.scale - result.response.mean_scaled;
        response_sum_squares.add(response * response);
        qr.add(row, response);
    }

    result.valid = qr.solve(result.beta, result.inverse_diagonal, result.residual_sse);
    if (result.valid)
    {
        /// Float64 arithmetic cannot distinguish an exact regression from a
        /// residual below the backward-error floor of the scaled design.  Use
        /// an explicit resolution policy rather than interpreting QR roundoff
        /// as genuine variance.  The bound accounts for the response energy,
        /// fitted-signal energy, and the number of Givens columns.  Real noise
        /// below this floor is intentionally reported as statistically
        /// unresolved rather than as an enormous, misleading t-ratio.
        const Float64 epsilon = std::numeric_limits<Float64>::epsilon();
        const Float64 gamma = epsilon / (1. - epsilon);
        TimeSeriesDiagnostics::CompensatedSum beta_sum_squares;
        for (size_t j = 0; j < columns; ++j)
            beta_sum_squares.add(result.beta[j] * result.beta[j]);
        const Float64 energy
            = std::max<Float64>(1., response_sum_squares.result() + design_sum_squares.result() * beta_sum_squares.result());
        const Float64 error_factor = 8. * static_cast<Float64>(columns) * gamma;
        result.residual_is_below_resolution = result.residual_sse <= error_factor * error_factor * energy;
    }
    return result;
}

struct LaggedResult
{
    Float64 intercept = nan();
    std::vector<Float64> coefficients;
};

template <typename Timestamp>
LaggedResult laggedRegression(KeyedState<Timestamp> & state, UInt64 order)
{
    LaggedResult result;
    result.coefficients.assign(order, nan());
    state.sortAndValidate();
    const auto & samples = state.samples.samples;
    if (samples.size() <= order)
        return result;
    const size_t rows = samples.size() - static_cast<size_t>(order);
    /// The fitted model has `order + 1` parameters including the recovered
    /// intercept. Keep the same positive-residual-df rule as the ADF fit.
    if (rows <= order + 1)
        return result;
    const auto fit = fitLeastSquares(
        rows,
        order,
        true,
        [&samples, order](size_t row_number, auto & row, Float64 & response)
        {
            const size_t t = row_number + static_cast<size_t>(order);
            response = samples[t].value;
            for (size_t j = 0; j < order; ++j)
                row[j] = samples[t - j - 1].value;
        });
    if (!fit.valid)
        return result;

    TimeSeriesDiagnostics::CompensatedSum intercept;
    intercept.add(fit.response.location + fit.response.scale * fit.response.mean_scaled);
    for (size_t j = 0; j < order; ++j)
    {
        const Float64 coefficient = fit.response.scale / fit.predictors[j].scale * fit.beta[j];
        if (!std::isfinite(coefficient))
            return LaggedResult{.intercept = nan(), .coefficients = std::vector<Float64>(order, nan())};
        result.coefficients[j] = coefficient;
        intercept.add(-coefficient * (fit.predictors[j].location + fit.predictors[j].scale * fit.predictors[j].mean_scaled));
    }
    result.intercept = intercept.result();
    if (!std::isfinite(result.intercept))
        return LaggedResult{.intercept = nan(), .coefficients = std::vector<Float64>(order, nan())};
    return result;
}

struct ADFResult
{
    Float64 statistic = nan();
    Float64 coefficient = nan();
    UInt64 observations = 0;
};

template <typename Timestamp>
ADFResult adfStatistic(KeyedState<Timestamp> & state, UInt64 augmentation_lags, ADFDeterministic deterministic)
{
    state.sortAndValidate();
    const auto & samples = state.samples.samples;
    const size_t p = static_cast<size_t>(augmentation_lags);
    ADFResult result;
    if (samples.size() <= p + 1)
        return result;
    const size_t rows = samples.size() - p - 1;
    result.observations = static_cast<UInt64>(rows);
    const bool has_trend = deterministic == ADFDeterministic::Trend;
    const size_t deterministic_terms = deterministic == ADFDeterministic::None ? 0 : (has_trend ? 2 : 1);
    /// Match statsmodels' fixed-lag admission rule exactly:
    /// p <= floor(n / 2) - deterministic_terms - 1.  Keep observations in
    /// the result even when this diagnostic feasibility check rejects a fit.
    if (samples.size() / 2 < p + deterministic_terms + 1)
        return result;
    const size_t columns = 1 + p + (has_trend ? 1 : 0);
    const bool center = deterministic != ADFDeterministic::None;
    /// Centering algebraically eliminates a constant column, but it does not
    /// eliminate an estimated parameter for residual degrees of freedom.
    const size_t model_parameters = columns + (center ? 1 : 0);
    if (rows <= model_parameters)
        return result;
    const auto fit = fitLeastSquares(
        rows,
        columns,
        center,
        [&samples, p, has_trend](size_t row_number, auto & row, Float64 & response)
        {
            const size_t t = row_number + p + 1;
            response = samples[t].value - samples[t - 1].value;
            row[0] = samples[t - 1].value;
            for (size_t lag = 1; lag <= p; ++lag)
                row[lag] = samples[t - lag].value - samples[t - lag - 1].value;
            if (has_trend)
                row[1 + p] = static_cast<Float64>(t);
        });
    if (!fit.valid)
        return result;
    if (fit.residual_is_below_resolution)
        return result;

    result.coefficient = fit.response.scale / fit.predictors[0].scale * fit.beta[0];
    const Float64 degrees_of_freedom = static_cast<Float64>(rows - model_parameters);
    const Float64 variance = fit.residual_sse / degrees_of_freedom;
    const Float64 standard_error = std::abs(fit.response.scale / fit.predictors[0].scale) * std::sqrt(variance * fit.inverse_diagonal[0]);
    if (!(standard_error > 0) || !std::isfinite(standard_error) || !std::isfinite(result.coefficient))
    {
        result.coefficient = nan();
        return result;
    }
    result.statistic = result.coefficient / standard_error;
    if (!std::isfinite(result.statistic))
    {
        result.statistic = nan();
        result.coefficient = nan();
    }
    return result;
}

Float64 defaultKpssBandwidth(size_t n)
{
    if (n < 2)
        return 0;
    const Float64 automatic = std::floor(12. * std::pow(static_cast<Float64>(n) / 100., 0.25));
    return std::min<Float64>(static_cast<Float64>(n - 1), automatic);
}

struct KPSSResult
{
    Float64 statistic = nan();
    UInt64 bandwidth = 0;
    UInt64 observations = 0;
};

template <typename Timestamp>
KPSSResult kpssTest(KeyedState<Timestamp> & state, KPSSRegression regression, UInt64 requested_bandwidth)
{
    state.sortAndValidate();
    const auto & samples = state.samples.samples;
    const size_t n = samples.size();
    KPSSResult result{.observations = static_cast<UInt64>(n)};
    result.bandwidth = requested_bandwidth == DEFAULT_BANDWIDTH ? static_cast<UInt64>(defaultKpssBandwidth(n)) : requested_bandwidth;
    if (n < 2 || result.bandwidth >= n || result.bandwidth > HARD_MAX_KPSS_BANDWIDTH
        || (result.bandwidth && static_cast<UInt64>(n) > HARD_MAX_KPSS_WORK / result.bandwidth))
        return result;

    Float64 minimum = samples.front().value;
    Float64 maximum = minimum;
    for (const auto & sample : samples)
    {
        minimum = std::min(minimum, sample.value);
        maximum = std::max(maximum, sample.value);
    }
    const Float64 location = std::midpoint(minimum, maximum);
    const Float64 scale = std::max(std::abs(minimum - location), std::abs(maximum - location));
    if (!(scale > 0) || !std::isfinite(scale))
        return result;

    TimeSeriesDiagnostics::CompensatedSum mean_sum;
    for (const auto & sample : samples)
        mean_sum.add((sample.value - location) / scale);
    const Float64 mean = mean_sum.result() / static_cast<Float64>(n);
    Float64 slope = 0;
    const Float64 time_mean = static_cast<Float64>(n - 1) / 2.;
    if (regression == KPSSRegression::Trend)
    {
        TimeSeriesDiagnostics::CompensatedSum numerator;
        TimeSeriesDiagnostics::CompensatedSum denominator;
        for (size_t i = 0; i < n; ++i)
        {
            const Float64 centered_time = static_cast<Float64>(i) - time_mean;
            numerator.add(centered_time * ((samples[i].value - location) / scale - mean));
            denominator.add(centered_time * centered_time);
        }
        slope = numerator.result() / denominator.result();
        if (!std::isfinite(slope))
            return result;
    }

    const auto residual = [&samples, location, scale, mean, slope, time_mean](size_t i)
    { return (samples[i].value - location) / scale - mean - slope * (static_cast<Float64>(i) - time_mean); };
    TimeSeriesDiagnostics::CompensatedSum cumulative;
    TimeSeriesDiagnostics::CompensatedSum numerator;
    TimeSeriesDiagnostics::CompensatedSum gamma_zero;
    for (size_t i = 0; i < n; ++i)
    {
        const Float64 value = residual(i);
        cumulative.add(value);
        numerator.add(cumulative.result() * cumulative.result());
        gamma_zero.add(value * value);
    }
    TimeSeriesDiagnostics::CompensatedSum long_run_variance;
    long_run_variance.add(gamma_zero.result() / static_cast<Float64>(n));
    for (UInt64 lag = 1; lag <= result.bandwidth; ++lag)
    {
        TimeSeriesDiagnostics::CompensatedSum covariance;
        for (size_t i = static_cast<size_t>(lag); i < n; ++i)
            covariance.add(residual(i) * residual(i - static_cast<size_t>(lag)));
        const Float64 bartlett = 1. - static_cast<Float64>(lag) / static_cast<Float64>(result.bandwidth + 1);
        long_run_variance.add(2. * bartlett * covariance.result() / static_cast<Float64>(n));
    }
    const Float64 variance = long_run_variance.result();
    const Float64 eta = numerator.result() / (static_cast<Float64>(n) * static_cast<Float64>(n));
    if (!(variance > 0) || !std::isfinite(variance) || !std::isfinite(eta))
        return result;
    result.statistic = eta / variance;
    if (!std::isfinite(result.statistic))
        result.statistic = nan();
    return result;
}

struct Welford
{
    UInt64 count = 0;
    Float64 mean = 0;
    Float64 m2 = 0;

    void add(Float64 value)
    {
        ++count;
        const Float64 delta = value - mean;
        mean += delta / static_cast<Float64>(count);
        /// This is algebraically the ordinary Welford update
        /// delta * (value - new_mean), written as delta^2 * (n - 1) / n.
        /// In the usual spelling, adding two adjacent Float64 values can round
        /// new_mean to one endpoint, making value - new_mean spuriously zero
        /// and losing their positive within-segment SSE.  Here values have
        /// already been range-scaled, so delta^2 cannot overflow; this form
        /// preserves that representable residual and lets a later rescale
        /// honestly produce +Inf when the original-unit SSE overflows.
        const Float64 count_as_float = static_cast<Float64>(count);
        m2 += delta * delta * (count_as_float - 1.) / count_as_float;
    }
};

struct ChangePointResult
{
    UInt64 split_index = 0;
    Float64 score = nan();
    Float64 mean_before = nan();
    Float64 mean_after = nan();
    Float64 sse = nan();
};

template <typename Timestamp>
ChangePointResult meanShiftChangePoint(KeyedState<Timestamp> & state, UInt64 min_segment)
{
    state.sortAndValidate();
    const auto & samples = state.samples.samples;
    const size_t n = samples.size();
    if (min_segment > n / 2 || n < 2)
        return {};

    Float64 minimum = samples.front().value;
    Float64 maximum = minimum;
    for (const auto & sample : samples)
    {
        minimum = std::min(minimum, sample.value);
        maximum = std::max(maximum, sample.value);
    }
    const Float64 location = std::midpoint(minimum, maximum);
    const Float64 scale = std::max(std::abs(minimum - location), std::abs(maximum - location));
    if (!(scale > 0) || !std::isfinite(scale))
        return {};

    Welford total;
    for (const auto & sample : samples)
        total.add((sample.value - location) / scale);
    const Float64 total_sse = total.m2;
    if (!(total_sse > 0) || !std::isfinite(total_sse))
        return {};

    /// A suffix M2 cannot be recovered robustly by subtracting the prefix M2
    /// and the between-means term from total.m2.  At a strong level break those
    /// three terms are O(n), while the within-suffix SSE may be arbitrarily
    /// smaller; the subtraction can then erase it (or manufacture a residual
    /// from roundoff).  Store each directly accumulated suffix state instead.
    /// This is transient finalization memory only: persisted/merged aggregate
    /// state remains the exact keyed sample vector.  We deliberately build the
    /// suffixes with forward Welford updates (while traversing the input from
    /// the right) rather than using a reverse/remove formula, which would have
    /// the same cancellation problem.
    std::vector<Welford> suffix(n + 1);
    for (size_t index = n; index > 0; --index)
    {
        suffix[index - 1] = suffix[index];
        suffix[index - 1].add((samples[index - 1].value - location) / scale);
    }

    /// Independently accumulated total, prefix, and suffix Welford reductions
    /// can differ by more than a fixed number of ulps on a long series.  Use a
    /// conservative count-aware gamma_n envelope and preserve the first
    /// (earliest) canonical split when the improvement is not distinguishable
    /// at that scale.  There is no absolute floor, so genuinely tiny SSEs are
    /// not automatically turned into ties.
    const Float64 epsilon = std::numeric_limits<Float64>::epsilon();
    const Float64 accumulated_roundoff = static_cast<Float64>(n) * epsilon;
    const Float64 comparison_gamma = accumulated_roundoff / (1. - accumulated_roundoff);
    const auto isReliablySmaller = [comparison_gamma](Float64 candidate, Float64 incumbent)
    {
        if (!(candidate < incumbent))
            return false;
        const Float64 comparison_scale = std::max(std::abs(candidate), std::abs(incumbent));
        const Float64 tolerance = 8. * comparison_gamma * comparison_scale;
        return incumbent - candidate > tolerance;
    };

    Welford left;
    Float64 best_sse = std::numeric_limits<Float64>::infinity();
    ChangePointResult result;
    for (size_t split = 1; split < n; ++split)
    {
        left.add((samples[split - 1].value - location) / scale);
        if (split < min_segment || n - split < min_segment)
            continue;
        const Welford & right = suffix[split];
        const Float64 candidate_sse = left.m2 + right.m2;
        /// The first finite candidate must establish the incumbent; subsequent
        /// comparisons use the ulp-aware rule above to retain earliest ties.
        if (!result.split_index || isReliablySmaller(candidate_sse, best_sse))
        {
            best_sse = candidate_sse;
            result.split_index = static_cast<UInt64>(split);
            result.mean_before = location + scale * left.mean;
            result.mean_after = location + scale * right.mean;
        }
    }
    if (!result.split_index || !isReliablySmaller(best_sse, total_sse))
        return {};
    result.score = std::max<Float64>(0, 1. - best_sse / total_sse);
    /// Do not turn an exact huge-scale break into NaN through Inf * 0. For a
    /// nonzero scaled SSE, +Inf is the honest Float64 representation when the
    /// original-unit SSE overflows; the split and dimensionless score remain
    /// useful and deterministic.
    result.sse = best_sse == 0 ? 0 : best_sse * scale * scale;
    if (!std::isfinite(result.score) || !std::isfinite(result.mean_before) || !std::isfinite(result.mean_after) || std::isnan(result.sse))
        return {};
    return result;
}

void insertLaggedResult(IColumn & to, const LaggedResult & result)
{
    auto & tuple = assert_cast<ColumnTuple &>(to);
    assert_cast<ColumnFloat64 &>(tuple.getColumn(0)).getData().push_back(result.intercept);
    auto & coefficients = assert_cast<ColumnArray &>(tuple.getColumn(1));
    auto & offsets = coefficients.getOffsets();
    const size_t offset = offsets.empty() ? 0 : offsets.back();
    offsets.push_back(offset + result.coefficients.size());
    auto & data = assert_cast<ColumnFloat64 &>(coefficients.getData()).getData();
    data.insert(data.end(), result.coefficients.begin(), result.coefficients.end());
}

void insertADFResult(IColumn & to, const ADFResult & result)
{
    auto & tuple = assert_cast<ColumnTuple &>(to);
    assert_cast<ColumnFloat64 &>(tuple.getColumn(0)).getData().push_back(result.statistic);
    assert_cast<ColumnFloat64 &>(tuple.getColumn(1)).getData().push_back(result.coefficient);
    assert_cast<ColumnUInt64 &>(tuple.getColumn(2)).getData().push_back(result.observations);
}

void insertKPSSResult(IColumn & to, const KPSSResult & result)
{
    auto & tuple = assert_cast<ColumnTuple &>(to);
    assert_cast<ColumnFloat64 &>(tuple.getColumn(0)).getData().push_back(result.statistic);
    assert_cast<ColumnUInt64 &>(tuple.getColumn(1)).getData().push_back(result.bandwidth);
    assert_cast<ColumnUInt64 &>(tuple.getColumn(2)).getData().push_back(result.observations);
}

void insertChangePointResult(IColumn & to, const ChangePointResult & result)
{
    auto & tuple = assert_cast<ColumnTuple &>(to);
    assert_cast<ColumnUInt64 &>(tuple.getColumn(0)).getData().push_back(result.split_index);
    assert_cast<ColumnFloat64 &>(tuple.getColumn(1)).getData().push_back(result.score);
    assert_cast<ColumnFloat64 &>(tuple.getColumn(2)).getData().push_back(result.mean_before);
    assert_cast<ColumnFloat64 &>(tuple.getColumn(3)).getData().push_back(result.mean_after);
    assert_cast<ColumnFloat64 &>(tuple.getColumn(4)).getData().push_back(result.sse);
}

template <typename Timestamp>
class AggregateFunctionTimeSeriesStatisticalExtensions final
    : public IAggregateFunctionDataHelper<KeyedState<Timestamp>, AggregateFunctionTimeSeriesStatisticalExtensions<Timestamp>>
{
    using State = KeyedState<Timestamp>;
    using Base = IAggregateFunctionDataHelper<State, AggregateFunctionTimeSeriesStatisticalExtensions<Timestamp>>;
    using TimestampColumn = ColumnVectorOrDecimal<Timestamp>;

public:
    AggregateFunctionTimeSeriesStatisticalExtensions(String name_, Spec spec_, const DataTypes & arguments, const Array & parameters_)
        : Base(arguments, parameters_, resultType(spec_))
        , name(std::move(name_))
        , spec(std::move(spec_))
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
        this->data(place).serialize(buffer, spec.stateParameters());
    }

    void deserialize(AggregateDataPtr __restrict place, ReadBuffer & buffer, std::optional<size_t>, Arena *) const override
    {
        this->data(place).deserialize(buffer, spec.stateParameters());
    }

    void insertResultInto(AggregateDataPtr __restrict place, IColumn & to, Arena *) const override
    {
        State & state = this->data(place);
        if (spec.kind == Kind::LaggedLinearRegression)
            return insertLaggedResult(to, laggedRegression(state, spec.first));
        if (spec.kind == Kind::ADFStatistic)
            return insertADFResult(to, adfStatistic(state, spec.first, static_cast<ADFDeterministic>(spec.second)));
        if (spec.kind == Kind::KPSSTest)
            return insertKPSSResult(to, kpssTest(state, static_cast<KPSSRegression>(spec.first), spec.second));
        insertChangePointResult(to, meanShiftChangePoint(state, spec.first));
    }

private:
    String name;
    Spec spec;
};

AggregateFunctionPtr createAggregateFunctionTimeSeriesStatisticalExtensions(
    const String & name, const DataTypes & arguments, const Array & parameters, const Settings * settings)
{
    if (settings && (*settings)[Setting::enable_time_series_aggregate_functions] == 0
        && (*settings)[Setting::enable_time_series_table] == 0)
        throw Exception(
            ErrorCodes::UNKNOWN_AGGREGATE_FUNCTION,
            "Aggregate function {} is in private preview and disabled by default. Enable it with setting "
            "enable_time_series_aggregate_functions",
            name);

    assertBinary(name, arguments);
    const Spec spec = parseSpec(name, parameters);
    const DataTypePtr & timestamp_type = arguments[0];
    const DataTypePtr & value_type = arguments[1];
    if (!isNativeNumber(value_type))
        throw Exception(
            ErrorCodes::ILLEGAL_TYPE_OF_ARGUMENT,
            "Illegal value type {} for aggregate function {}, expected a native numeric type",
            value_type->getName(),
            name);

    if (isDateTime64(timestamp_type))
        return std::make_shared<AggregateFunctionTimeSeriesStatisticalExtensions<DateTime64>>(name, spec, arguments, parameters);
    if (isDateTime(timestamp_type) || isUInt32(timestamp_type))
        return std::make_shared<AggregateFunctionTimeSeriesStatisticalExtensions<UInt32>>(name, spec, arguments, parameters);
    if (isUInt64(timestamp_type))
        return std::make_shared<AggregateFunctionTimeSeriesStatisticalExtensions<UInt64>>(name, spec, arguments, parameters);
    throw Exception(
        ErrorCodes::ILLEGAL_TYPE_OF_ARGUMENT,
        "Illegal timestamp type {} for aggregate function {}, expected UInt32, UInt64, DateTime, or DateTime64",
        timestamp_type->getName(),
        name);
}

FunctionDocumentation extensionDocumentation(
    const String & description,
    const String & syntax,
    const FunctionDocumentation::Parameters & parameters,
    const FunctionDocumentation::ReturnedValue & returned_value)
{
    const FunctionDocumentation::Arguments arguments = {
        {"timestamp",
         "Unique ordering key. Samples are sorted before calculation; spacing between keys is ignored.",
         {"UInt32", "UInt64", "DateTime", "DateTime64"}},
        {"value",
         "Finite native numeric time-series value. Rows with NULL in either argument are skipped by the Null combinator.",
         {"(U)Int*", "Float*"}},
    };
    return {description, syntax, arguments, parameters, returned_value, {}, {26, 9}, FunctionDocumentation::Category::AggregateFunction};
}

}

void registerAggregateFunctionsTimeSeriesStatisticalExtensions(AggregateFunctionFactory &);
void registerAggregateFunctionsTimeSeriesStatisticalExtensions(AggregateFunctionFactory & factory)
{
    factory.registerFunction(
        "timeSeriesLaggedLinearRegression",
        {createAggregateFunctionTimeSeriesStatisticalExtensions,
         extensionDocumentation(
             R"(Fits the positional autoregression `y_t = intercept + sum(coefficients[j - 1] * y_(t-j))` after exact timestamp ordering. The state retains all keyed samples so arbitrary distributed merges are exact. It uses centered/scaled streaming Givens QR without column pivoting and rejects a scaled reciprocal condition estimate below `1e-12`. Insufficient, rank-deficient, ill-conditioned, or non-finite fits return NaNs. `order` is capped at 16; the O(n * order^2) finalizer returns NaNs when `rows * order^2` exceeds 100000000.

:::note
This function is in private preview. Enable it with `enable_time_series_aggregate_functions`.
:::)",
             "timeSeriesLaggedLinearRegression(order[, max_samples])(timestamp, value)",
             {{"order", "Positive number of consecutive positional lags, from 1 through 16.", {"UInt64"}},
              {"max_samples", "Positive keyed-state cap; default 1000000.", {"UInt64"}}},
             {"Returns `(intercept, coefficients)` with coefficients in lag order 1 through order.",
              {"Tuple(intercept Float64, coefficients Array(Float64))"}})});

    factory.registerFunction(
        "timeSeriesADFStatistic",
        {createAggregateFunctionTimeSeriesStatisticalExtensions,
         extensionDocumentation(
             R"(Computes the coefficient and t-statistic of `y_(t-1)` in a fixed-lag augmented Dickey-Fuller regression. `deterministic` is `none`, `constant` (default), or `trend`; no autolag selection or p-value is performed. The fixed-lag sample-admission rule matches statsmodels. Gaps in numeric timestamps are ignored, so callers requiring equally spaced inference must resample first. The centered/scaled Givens QR has no column pivoting, rejects a scaled reciprocal condition estimate below `1e-12`, and treats residual variance below its documented Float64 backward-error floor as unresolved. Undefined fits, or fits for which `rows * columns^2` exceeds 100000000, return NaN statistic and coefficient while retaining the usable observation count.

:::note
This function is in private preview. Enable it with `enable_time_series_aggregate_functions`.
:::)",
             "timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])(timestamp, value)",
             {{"augmentation_lags", "Number of lagged first differences, from 0 through 16.", {"UInt64"}},
              {"deterministic", "none, constant, or trend; default constant.", {"String"}},
              {"max_samples", "Positive keyed-state cap; default 1000000.", {"UInt64"}}},
             {"Returns `(statistic, coefficient, observations)`, where observations is the number of usable post-lag regression rows; no "
              "p-value is estimated.",
              {"Tuple(statistic Float64, coefficient Float64, observations UInt64)"}})});

    factory.registerFunction(
        "timeSeriesKPSSTest",
        {createAggregateFunctionTimeSeriesStatisticalExtensions,
         extensionDocumentation(
             R"(Computes the KPSS statistic for a level or trend regression using a Bartlett/Newey-West long-run variance estimate. Omitted bandwidth follows this function's explicit floor convention, `min(n - 1, floor(12 * (n / 100)^0.25))`; it is not an alias for another library's legacy mode. An explicit bandwidth must be below `max_samples`, is capped at 1024, and must also be below the observed `n` to produce a statistic. Finalization returns NaN above 100000000 `n * bandwidth` lag products. Gaps in numeric timestamps are ignored; this function returns no p-value.

:::note
This function is in private preview. Enable it with `enable_time_series_aggregate_functions`.
:::)",
             "timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])(timestamp, value)",
             {{"regression", "level or trend.", {"String"}},
              {"bandwidth", "Optional non-negative Bartlett bandwidth.", {"UInt64"}},
              {"max_samples", "Positive keyed-state cap; default 1000000.", {"UInt64"}}},
             {"Returns `(statistic, bandwidth, observations)`; no p-value is estimated.",
              {"Tuple(statistic Float64, bandwidth UInt64, observations UInt64)"}})});

    factory.registerFunction(
        "timeSeriesMeanShiftChangePoint",
        {createAggregateFunctionTimeSeriesStatisticalExtensions,
         extensionDocumentation(
             R"(Finds the split into two constant-mean segments that minimizes within-segment SSE, after exact timestamp ordering. `split_index` is the number of samples in the left segment. `score` is dimensionless relative SSE reduction, not a p-value. With `gamma_n = n * epsilon / (1 - n * epsilon)`, a later optimum is accepted only when its SSE improves by more than `8 * gamma_n * max(abs(candidate), abs(incumbent))`; otherwise the earliest split is retained. No identifiable improvement returns split_index 0 and NaNs. The persisted state is O(n), and finalization uses O(n) transient suffix statistics to avoid cancellation. A positive original-unit SSE that overflows Float64 is returned as +Inf without discarding a valid split; a tiny one may underflow to zero.

:::note
This function is in private preview. Enable it with `enable_time_series_aggregate_functions`.
:::)",
             "timeSeriesMeanShiftChangePoint(min_segment[, max_samples])(timestamp, value)",
             {{"min_segment", "Positive minimum sample count on each side of the split.", {"UInt64"}},
              {"max_samples", "Positive keyed-state cap; default 1000000.", {"UInt64"}}},
             {"Returns `(split_index, score, mean_before, mean_after, sse)`.",
              {"Tuple(split_index UInt64, score Float64, mean_before Float64, mean_after Float64, sse Float64)"}})});
}

}
