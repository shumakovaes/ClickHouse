#include <AggregateFunctions/AggregateFunctionFactory.h>
#include <AggregateFunctions/IAggregateFunction.h>
#include <AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.h>

#include <Columns/ColumnArray.h>
#include <Columns/ColumnTuple.h>
#include <Columns/ColumnsNumber.h>
#include <DataTypes/DataTypesNumber.h>
#include <IO/ReadBufferFromString.h>
#include <IO/WriteBufferFromString.h>
#include <Common/AlignedBuffer.h>
#include <Common/assert_cast.h>
#include <Common/tests/gtest_global_register.h>

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <initializer_list>
#include <limits>
#include <memory>
#include <random>
#include <string>
#include <utility>
#include <vector>

namespace
{

namespace Extension = DB::TimeSeriesStatisticalExtensions;
using State = Extension::KeyedState<UInt64>;
using Parameters = Extension::Parameters;

constexpr UInt64 max_samples = 32;

State makeState(std::initializer_list<std::pair<UInt64, Float64>> points, UInt64 limit = max_samples)
{
    State state;
    for (const auto & [timestamp, value] : points)
        state.add(timestamp, value, limit);
    return state;
}

Parameters parameters(Extension::Kind kind, UInt64 first, UInt64 second = 0, UInt64 third = 0, UInt64 limit = max_samples)
{
    return Parameters{.kind = kind, .first = first, .second = second, .third = third, .max_samples = limit};
}

void expectSamples(const State & state, const std::vector<std::pair<UInt64, Float64>> & expected)
{
    ASSERT_EQ(state.samples.samples.size(), expected.size());
    for (size_t i = 0; i < expected.size(); ++i)
    {
        EXPECT_EQ(state.samples.samples[i].timestamp, expected[i].first);
        EXPECT_DOUBLE_EQ(state.samples.samples[i].value, expected[i].second);
    }
}

std::string serialize(const State & state, const Parameters & spec)
{
    DB::WriteBufferFromOwnString output;
    state.serialize(output, spec);
    return output.str();
}

State deserialize(const std::string & payload, const Parameters & spec)
{
    State state;
    DB::ReadBufferFromString input(payload);
    state.deserialize(input, spec);
    return state;
}

void expectSameSamples(const State & lhs, const State & rhs)
{
    ASSERT_EQ(lhs.samples.samples.size(), rhs.samples.samples.size());
    for (size_t i = 0; i < lhs.samples.samples.size(); ++i)
    {
        EXPECT_EQ(lhs.samples.samples[i].timestamp, rhs.samples.samples[i].timestamp);
        EXPECT_DOUBLE_EQ(lhs.samples.samples[i].value, rhs.samples.samples[i].value);
    }
}

DB::MutableColumnPtr runAggregate(const String & name, const DB::Array & params, const std::vector<std::pair<UInt64, Float64>> & points)
{
    tryRegisterAggregateFunctions();
    DB::DataTypes arguments{std::make_shared<DB::DataTypeUInt64>(), std::make_shared<DB::DataTypeFloat64>()};
    DB::AggregateFunctionProperties properties;
    auto function = DB::AggregateFunctionFactory::instance().get(name, DB::NullsAction::EMPTY, arguments, params, properties);

    DB::AlignedBuffer place(function->sizeOfData(), function->alignOfData());
    function->create(place.data());
    DB::MutableColumnPtr result;
    try
    {
        auto timestamps = DB::ColumnUInt64::create();
        auto values = DB::ColumnFloat64::create();
        for (const auto & [timestamp, value] : points)
        {
            timestamps->getData().push_back(timestamp);
            values->getData().push_back(value);
        }
        const DB::IColumn * columns[]{timestamps.get(), values.get()};
        for (size_t row = 0; row < points.size(); ++row)
            function->add(place.data(), columns, row, nullptr);
        result = function->getResultType()->createColumn();
        function->insertResultInto(place.data(), *result, nullptr);
    }
    catch (...)
    {
        function->destroy(place.data());
        throw;
    }
    function->destroy(place.data());
    return result;
}

struct AggregateStateSet
{
    struct Slot
    {
        std::unique_ptr<DB::AlignedBuffer> state;
        bool initialized = false;
    };

    DB::AggregateFunctionPtr function;
    std::vector<Slot> states;

    ~AggregateStateSet()
    {
        for (auto & slot : states)
        {
            if (slot.initialized)
            {
                slot.initialized = false;
                function->destroy(slot.state->data());
            }
        }
    }

    void addState()
    {
        auto state = std::make_unique<DB::AlignedBuffer>(function->sizeOfData(), function->alignOfData());
        function->create(state->data());
        Slot slot{.state = std::move(state), .initialized = true};
        try
        {
            states.push_back(std::move(slot));
        }
        catch (...)
        {
            if (slot.state)
            {
                slot.initialized = false;
                function->destroy(slot.state->data());
            }
            throw;
        }
    }

    void destroyAndErase(size_t index)
    {
        states[index].initialized = false;
        function->destroy(states[index].state->data());
        states.erase(states.begin() + index);
    }
};

DB::MutableColumnPtr runAggregateWithChunks(
    const String & name,
    const DB::Array & params,
    const std::vector<std::vector<std::pair<UInt64, Float64>>> & chunks,
    std::mt19937_64 & rng)
{
    tryRegisterAggregateFunctions();
    DB::DataTypes arguments{std::make_shared<DB::DataTypeUInt64>(), std::make_shared<DB::DataTypeFloat64>()};
    DB::AggregateFunctionProperties properties;
    AggregateStateSet state_set;
    state_set.function = DB::AggregateFunctionFactory::instance().get(name, DB::NullsAction::EMPTY, arguments, params, properties);
    state_set.states.reserve(std::max<size_t>(chunks.size(), 1));

    for (const auto & chunk : chunks)
    {
        state_set.addState();
        auto timestamps = DB::ColumnUInt64::create();
        auto values = DB::ColumnFloat64::create();
        for (const auto & [timestamp, value] : chunk)
        {
            timestamps->getData().push_back(timestamp);
            values->getData().push_back(value);
        }
        const DB::IColumn * columns[]{timestamps.get(), values.get()};
        for (size_t row = 0; row < chunk.size(); ++row)
            state_set.function->add(state_set.states.back().state->data(), columns, row, nullptr);
    }

    if (state_set.states.empty())
        state_set.addState();

    while (state_set.states.size() > 1)
    {
        size_t left = static_cast<size_t>(rng() % state_set.states.size());
        size_t right = static_cast<size_t>(rng() % (state_set.states.size() - 1));
        if (right >= left)
            ++right;
        if (right < left)
            std::swap(left, right);
        state_set.function->merge(state_set.states[left].state->data(), state_set.states[right].state->data(), nullptr);
        state_set.destroyAndErase(right);
    }

    auto result = state_set.function->getResultType()->createColumn();
    state_set.function->insertResultInto(state_set.states.front().state->data(), *result, nullptr);
    return result;
}

template <typename ColumnPointer>
const DB::ColumnTuple & resultTuple(const ColumnPointer & result)
{
    return assert_cast<const DB::ColumnTuple &>(*result);
}

DB::Array numericParameters(std::initializer_list<UInt64> values)
{
    DB::Array result;
    for (UInt64 value : values)
        result.emplace_back(value);
    return result;
}

DB::Array adfParameters(const String & deterministic)
{
    DB::Array result;
    result.emplace_back(UInt64{0});
    result.emplace_back(deterministic);
    return result;
}

DB::Array adfParameters(UInt64 augmentation_lags, const String & deterministic)
{
    DB::Array result;
    result.emplace_back(augmentation_lags);
    result.emplace_back(deterministic);
    return result;
}

DB::Array kpssParameters(const String & regression, UInt64 bandwidth)
{
    DB::Array result;
    result.emplace_back(regression);
    result.emplace_back(bandwidth);
    return result;
}

DB::Array kpssParameters(const String & regression)
{
    return DB::Array{DB::Field(regression)};
}

void expectFloatResultsEqual(Float64 lhs, Float64 rhs)
{
    if (std::isnan(lhs) || std::isnan(rhs))
        EXPECT_TRUE(std::isnan(lhs) && std::isnan(rhs));
    else
        EXPECT_DOUBLE_EQ(lhs, rhs);
}

void expectFinalizersEqual(Extension::Kind kind, const DB::MutableColumnPtr & lhs_result, const DB::MutableColumnPtr & rhs_result)
{
    const auto & lhs = resultTuple(lhs_result);
    const auto & rhs = resultTuple(rhs_result);
    if (kind == Extension::Kind::LaggedLinearRegression)
    {
        expectFloatResultsEqual(
            assert_cast<const DB::ColumnFloat64 &>(lhs.getColumn(0)).getElement(0),
            assert_cast<const DB::ColumnFloat64 &>(rhs.getColumn(0)).getElement(0));
        const auto & lhs_coefficients = assert_cast<const DB::ColumnArray &>(lhs.getColumn(1));
        const auto & rhs_coefficients = assert_cast<const DB::ColumnArray &>(rhs.getColumn(1));
        ASSERT_EQ(lhs_coefficients.getOffsets(), rhs_coefficients.getOffsets());
        ASSERT_EQ(lhs_coefficients.getData().size(), rhs_coefficients.getData().size());
        for (size_t i = 0; i < lhs_coefficients.getData().size(); ++i)
            expectFloatResultsEqual(
                assert_cast<const DB::ColumnFloat64 &>(lhs_coefficients.getData()).getElement(i),
                assert_cast<const DB::ColumnFloat64 &>(rhs_coefficients.getData()).getElement(i));
        return;
    }

    if (kind == Extension::Kind::ADFStatistic)
    {
        for (size_t i = 0; i < 2; ++i)
            expectFloatResultsEqual(
                assert_cast<const DB::ColumnFloat64 &>(lhs.getColumn(i)).getElement(0),
                assert_cast<const DB::ColumnFloat64 &>(rhs.getColumn(i)).getElement(0));
        EXPECT_EQ(
            assert_cast<const DB::ColumnUInt64 &>(lhs.getColumn(2)).getElement(0),
            assert_cast<const DB::ColumnUInt64 &>(rhs.getColumn(2)).getElement(0));
        return;
    }

    if (kind == Extension::Kind::KPSSTest)
    {
        expectFloatResultsEqual(
            assert_cast<const DB::ColumnFloat64 &>(lhs.getColumn(0)).getElement(0),
            assert_cast<const DB::ColumnFloat64 &>(rhs.getColumn(0)).getElement(0));
        for (size_t i = 1; i < 3; ++i)
            EXPECT_EQ(
                assert_cast<const DB::ColumnUInt64 &>(lhs.getColumn(i)).getElement(0),
                assert_cast<const DB::ColumnUInt64 &>(rhs.getColumn(i)).getElement(0));
        return;
    }

    EXPECT_EQ(
        assert_cast<const DB::ColumnUInt64 &>(lhs.getColumn(0)).getElement(0),
        assert_cast<const DB::ColumnUInt64 &>(rhs.getColumn(0)).getElement(0));
    for (size_t i = 1; i < 5; ++i)
        expectFloatResultsEqual(
            assert_cast<const DB::ColumnFloat64 &>(lhs.getColumn(i)).getElement(0),
            assert_cast<const DB::ColumnFloat64 &>(rhs.getColumn(i)).getElement(0));
}

} // namespace

TEST(TimeSeriesStatisticalExtensionsState, HandFixturesCoverAllFourKinds)
{
    const std::vector<std::pair<Extension::Kind, Parameters>> specs = {
        {Extension::Kind::LaggedLinearRegression, parameters(Extension::Kind::LaggedLinearRegression, 1)},
        {Extension::Kind::ADFStatistic, parameters(Extension::Kind::ADFStatistic, 0, 1)},
        {Extension::Kind::KPSSTest, parameters(Extension::Kind::KPSSTest, 0, 0)},
        {Extension::Kind::MeanShiftChangePoint, parameters(Extension::Kind::MeanShiftChangePoint, 1)},
    };

    /// y = 1,2,3,4,5 is an exact order-one line, while the latter fixture is
    /// a zero-SSE level shift at split 3.  ADF/KPSS receive a non-constant
    /// deterministic fixture so their finalizers are not accidentally tested
    /// only on undefined constant input.
    const auto linear = makeState({{4, 5}, {0, 1}, {3, 4}, {1, 2}, {2, 3}});
    const auto level_shift = makeState({{5, 10}, {0, 0}, {3, 10}, {1, 0}, {4, 10}, {2, 0}});

    for (const auto & [kind, spec] : specs)
    {
        const State & source = kind == Extension::Kind::MeanShiftChangePoint ? level_shift : linear;
        State canonical = source;
        canonical.sortAndValidate();
        expectSamples(
            canonical,
            kind == Extension::Kind::MeanShiftChangePoint
                ? std::vector<std::pair<UInt64, Float64>>{{0, 0}, {1, 0}, {2, 0}, {3, 10}, {4, 10}, {5, 10}}
                : std::vector<std::pair<UInt64, Float64>>{{0, 1}, {1, 2}, {2, 3}, {3, 4}, {4, 5}});
        EXPECT_EQ(spec.kind, kind);
    }
}

TEST(TimeSeriesStatisticalExtensionsState, ShuffledOrderAndInterleavedMergeAreEquivalent)
{
    const auto direct = makeState({{8, 8}, {1, 1}, {6, 6}, {3, 3}, {0, 0}, {7, 7}, {2, 2}, {5, 5}, {4, 4}});
    State canonical = direct;
    canonical.sortAndValidate();

    State a = makeState({{8, 8}, {1, 1}, {6, 6}});
    State b = makeState({{3, 3}, {0, 0}, {7, 7}});
    State c = makeState({{2, 2}, {5, 5}, {4, 4}});
    a.merge(b, max_samples);
    a.merge(c, max_samples);
    expectSameSamples(a, canonical);

    State left = makeState({{8, 8}, {1, 1}, {6, 6}});
    State right = makeState({{3, 3}, {0, 0}, {7, 7}});
    State tail = makeState({{2, 2}, {5, 5}, {4, 4}});
    right.merge(tail, max_samples);
    left.merge(right, max_samples);
    expectSameSamples(left, canonical);
}

TEST(TimeSeriesStatisticalExtensionsState, CanonicalEnvelopeBytesIgnoreInputAndMergeOrder)
{
    const std::vector<Parameters> specs = {
        parameters(Extension::Kind::LaggedLinearRegression, 1),
        parameters(Extension::Kind::ADFStatistic, 0, 1),
        parameters(Extension::Kind::KPSSTest, 0, 0),
        parameters(Extension::Kind::MeanShiftChangePoint, 1),
    };
    const State ordered = makeState({{0, 1}, {1, 2}, {2, 4}, {3, 8}, {4, 16}, {5, 32}});
    const State shuffled = makeState({{4, 16}, {1, 2}, {5, 32}, {0, 1}, {3, 8}, {2, 4}});
    State first = makeState({{4, 16}, {1, 2}});
    State second = makeState({{5, 32}, {0, 1}});
    State third = makeState({{3, 8}, {2, 4}});
    second.merge(third, max_samples);
    first.merge(second, max_samples);

    for (const auto & spec : specs)
    {
        const std::string expected = serialize(ordered, spec);
        EXPECT_EQ(serialize(shuffled, spec), expected);
        EXPECT_EQ(serialize(first, spec), expected);
        expectSameSamples(deserialize(expected, spec), ordered);
    }
}

TEST(TimeSeriesStatisticalExtensionsState, SerializationRoundTripAndEnvelopeParameterMismatch)
{
    const auto spec = parameters(Extension::Kind::KPSSTest, 0, 1, 0, max_samples);
    const auto source = makeState({{4, 5}, {1, 2}, {3, 4}, {0, 1}, {2, 3}});
    const std::string payload = serialize(source, spec);
    const State restored = deserialize(payload, spec);
    State canonical = source;
    canonical.sortAndValidate();
    expectSameSamples(restored, canonical);

    const auto wrong_kind = parameters(Extension::Kind::ADFStatistic, 0, 1, 0, max_samples);
    EXPECT_THROW(deserialize(payload, wrong_kind), DB::Exception);
    const auto wrong_parameter = parameters(Extension::Kind::KPSSTest, 0, 2, 0, max_samples);
    EXPECT_THROW(deserialize(payload, wrong_parameter), DB::Exception);
    const auto wrong_cap = parameters(Extension::Kind::KPSSTest, 0, 1, 0, max_samples - 1);
    EXPECT_THROW(deserialize(payload, wrong_cap), DB::Exception);
}

TEST(TimeSeriesStatisticalExtensionsState, CorruptEnvelopeAndTruncatedPayloadsAreRejected)
{
    const auto spec = parameters(Extension::Kind::MeanShiftChangePoint, 1);
    const auto source = makeState({{0, 0}, {1, 1}, {2, 2}});
    const std::string valid = serialize(source, spec);

    std::string bad_version = valid;
    bad_version[0] = static_cast<char>(2);
    EXPECT_THROW(deserialize(bad_version, spec), DB::Exception);

    std::string bad_kind = valid;
    bad_kind[2] = static_cast<char>(99);
    EXPECT_THROW(deserialize(bad_kind, spec), DB::Exception);

    for (size_t size = 0; size < valid.size(); ++size)
        EXPECT_THROW(deserialize(valid.substr(0, size), spec), DB::Exception);
}

TEST(TimeSeriesStatisticalExtensionsState, DuplicateNonFiniteAndCapsAreRejected)
{
    State duplicate = makeState({{2, 1}, {2, 2}});
    EXPECT_THROW(duplicate.sortAndValidate(), DB::Exception);

    State lhs = makeState({{0, 0}, {2, 2}});
    State rhs = makeState({{1, 1}, {2, 3}});
    EXPECT_THROW(lhs.merge(rhs, max_samples), DB::Exception);

    State nonfinite;
    EXPECT_THROW(nonfinite.add(0, std::numeric_limits<Float64>::quiet_NaN(), max_samples), DB::Exception);
    EXPECT_THROW(nonfinite.add(0, std::numeric_limits<Float64>::infinity(), max_samples), DB::Exception);
    EXPECT_THROW(nonfinite.add(0, -std::numeric_limits<Float64>::infinity(), max_samples), DB::Exception);

    State capped;
    capped.add(0, 0, 2);
    capped.add(1, 1, 2);
    EXPECT_THROW(capped.add(2, 2, 2), DB::Exception);
    EXPECT_THROW(capped.add(2, 2, 0), DB::Exception);
    EXPECT_THROW(capped.add(2, 2, DB::TimeSeriesDiagnostics::HARD_MAX_SAMPLES + 1), DB::Exception);

    State merge_left = makeState({{0, 0}, {2, 2}}, 3);
    State merge_right = makeState({{1, 1}, {3, 3}}, 3);
    EXPECT_THROW(merge_left.merge(merge_right, 3), DB::Exception);
}

TEST(TimeSeriesStatisticalExtensionsState, DegenerateFixturesRemainCanonical)
{
    const auto constant = makeState({{3, 7}, {0, 7}, {2, 7}, {1, 7}});
    State ordered = constant;
    ordered.sortAndValidate();
    expectSamples(ordered, {{0, 7}, {1, 7}, {2, 7}, {3, 7}});

    const auto singleton = makeState({{42, 1}});
    const auto empty = State{};
    const auto spec = parameters(Extension::Kind::ADFStatistic, 0, 1);
    EXPECT_NO_THROW(deserialize(serialize(singleton, spec), spec));
    EXPECT_NO_THROW(deserialize(serialize(empty, spec), spec));
}

TEST(TimeSeriesStatisticalExtensionsState, FixedSeedRandomizedChunkingAndMergeTreesPreserveStateAndFinalizers)
{
    constexpr UInt64 randomized_max_samples = 64;
    constexpr size_t rounds = 12;
    constexpr size_t chunkings_per_round = 6;
    std::mt19937_64 rng(0x5EED5EED12345678ULL);

    struct RandomizedSpec
    {
        Extension::Kind kind;
        String function_name;
        DB::Array aggregate_parameters;
        Parameters state_parameters;
    };

    const std::vector<RandomizedSpec> specs = {
        {Extension::Kind::LaggedLinearRegression,
         "timeSeriesLaggedLinearRegression",
         numericParameters({2, randomized_max_samples}),
         parameters(Extension::Kind::LaggedLinearRegression, 2, 0, 0, randomized_max_samples)},
        {Extension::Kind::ADFStatistic,
         "timeSeriesADFStatistic",
         DB::Array{DB::Field(UInt64{1}), DB::Field(String{"constant"}), DB::Field(randomized_max_samples)},
         parameters(Extension::Kind::ADFStatistic, 1, 1, 0, randomized_max_samples)},
        {Extension::Kind::KPSSTest,
         "timeSeriesKPSSTest",
         DB::Array{DB::Field(String{"level"}), DB::Field(UInt64{2}), DB::Field(randomized_max_samples)},
         parameters(Extension::Kind::KPSSTest, 0, 2, 0, randomized_max_samples)},
        {Extension::Kind::MeanShiftChangePoint,
         "timeSeriesMeanShiftChangePoint",
         numericParameters({3, randomized_max_samples}),
         parameters(Extension::Kind::MeanShiftChangePoint, 3, 0, 0, randomized_max_samples)},
    };

    for (size_t round = 0; round < rounds; ++round)
    {
        const size_t point_count = round < 3 ? round : 8 + static_cast<size_t>(rng() % 17);
        const UInt64 timestamp_base = 1'000'000 + static_cast<UInt64>(round) * 1'000;
        std::vector<std::pair<UInt64, Float64>> points;
        points.reserve(point_count);
        for (size_t i = 0; i < point_count; ++i)
        {
            const Float64 phase = static_cast<Float64>((round + 1) * (i + 3));
            const Float64 value = 0.25 * static_cast<Float64>(i) + std::sin(phase) + 0.5 * std::cos(phase * 0.37);
            points.emplace_back(timestamp_base + static_cast<UInt64>(i), value);
        }

        State canonical;
        for (const auto & [timestamp, value] : points)
            canonical.add(timestamp, value, randomized_max_samples);
        canonical.sortAndValidate();

        for (const auto & spec : specs)
        {
            const std::string expected_bytes = serialize(canonical, spec.state_parameters);
            const auto direct_result = runAggregate(spec.function_name, spec.aggregate_parameters, points);
            for (size_t chunking = 0; chunking < chunkings_per_round; ++chunking)
            {
                SCOPED_TRACE(
                    testing::Message() << "round=" << round << ", chunking=" << chunking << ", kind=" << static_cast<UInt64>(spec.kind));
                std::vector<std::pair<UInt64, Float64>> shuffled = points;
                std::shuffle(shuffled.begin(), shuffled.end(), rng);
                const size_t chunk_count = 2 + static_cast<size_t>(rng() % 7);
                std::vector<std::vector<std::pair<UInt64, Float64>>> chunks(chunk_count);
                for (const auto & point : shuffled)
                    chunks[static_cast<size_t>(rng() % chunk_count)].push_back(point);

                std::vector<State> states;
                states.reserve(chunks.size());
                for (const auto & chunk : chunks)
                {
                    State state;
                    for (const auto & [timestamp, value] : chunk)
                        state.add(timestamp, value, randomized_max_samples);
                    states.push_back(std::move(state));
                }
                while (states.size() > 1)
                {
                    size_t left = static_cast<size_t>(rng() % states.size());
                    size_t right = static_cast<size_t>(rng() % (states.size() - 1));
                    if (right >= left)
                        ++right;
                    if (right < left)
                        std::swap(left, right);
                    states[left].merge(states[right], randomized_max_samples);
                    states.erase(states.begin() + right);
                }

                ASSERT_EQ(serialize(states.front(), spec.state_parameters), expected_bytes);
                const auto merged_result = runAggregateWithChunks(spec.function_name, spec.aggregate_parameters, chunks, rng);
                expectFinalizersEqual(spec.kind, direct_result, merged_result);
            }
        }
    }
}

TEST(TimeSeriesStatisticalExtensionsAggregate, LaggedRegressionExactAndShuffled)
{
    /// y[t] = 1 + 2*y[t-1], represented in reverse timestamp order.
    const auto result
        = runAggregate("timeSeriesLaggedLinearRegression", numericParameters({1}), {{4, 31}, {0, 1}, {3, 15}, {1, 3}, {2, 7}});
    const auto & tuple = resultTuple(result);
    EXPECT_NEAR(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(0)).getElement(0), 1.0, 1e-12);
    const auto & coefficients = assert_cast<const DB::ColumnArray &>(tuple.getColumn(1));
    ASSERT_EQ(coefficients.getOffsets().back(), 1);
    EXPECT_NEAR(assert_cast<const DB::ColumnFloat64 &>(coefficients.getData()).getElement(0), 2.0, 1e-12);
}

TEST(TimeSeriesStatisticalExtensionsAggregate, ADFMatchesFixedRegressionGoldenForAllDeterministics)
{
    const std::vector<std::pair<UInt64, Float64>> points = {{5, 4}, {0, 1}, {3, 3}, {1, 2}, {4, 2}, {2, 1}};
    const std::vector<std::pair<String, Float64>> expected
        = {{"none", 0.2793721183078314}, {"constant", -1.5627711032415346}, {"trend", -6.666666666666669}};
    for (const auto & [deterministic, statistic] : expected)
    {
        const auto result = runAggregate("timeSeriesADFStatistic", adfParameters(deterministic), points);
        const auto & tuple = resultTuple(result);
        EXPECT_NEAR(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(0)).getElement(0), statistic, 1e-10) << deterministic;
        EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tuple.getColumn(2)).getElement(0), 5);
    }
}

TEST(TimeSeriesStatisticalExtensionsAggregate, KPSSLevelBandwidthZeroHandFixture)
{
    const auto result = runAggregate("timeSeriesKPSSTest", kpssParameters("level", 0), {{3, 1}, {0, 0}, {2, 1}, {1, 0}});
    const auto & tuple = resultTuple(result);
    EXPECT_NEAR(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(0)).getElement(0), 0.375, 1e-14);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tuple.getColumn(1)).getElement(0), 0);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tuple.getColumn(2)).getElement(0), 4);
}

TEST(TimeSeriesStatisticalExtensionsAggregate, MeanShiftChangePointHandFixture)
{
    const auto result
        = runAggregate("timeSeriesMeanShiftChangePoint", numericParameters({1}), {{5, 10}, {0, 0}, {3, 10}, {1, 0}, {4, 10}, {2, 0}});
    const auto & tuple = resultTuple(result);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tuple.getColumn(0)).getElement(0), 3);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(1)).getElement(0), 1.0);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(2)).getElement(0), 0.0);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(3)).getElement(0), 10.0);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(4)).getElement(0), 0.0);
}

TEST(TimeSeriesStatisticalExtensionsAggregate, MeanShiftTieUsesEarliestSplitAndStableLargeOffsets)
{
    /// [0,10,0] has equal SSE at splits 1 and 2; the contract keeps split 1.
    const auto tie = runAggregate("timeSeriesMeanShiftChangePoint", numericParameters({1}), {{2, 0}, {0, 0}, {1, 10}});
    const auto & tie_tuple = resultTuple(tie);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tie_tuple.getColumn(0)).getElement(0), 1);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(tie_tuple.getColumn(2)).getElement(0), 0.0);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(tie_tuple.getColumn(3)).getElement(0), 5.0);

    constexpr UInt64 last = std::numeric_limits<UInt64>::max();
    constexpr Float64 offset = 1e16;
    const auto large = runAggregate(
        "timeSeriesMeanShiftChangePoint",
        numericParameters({1}),
        {{last, offset + 4096}, {0, offset}, {last - 1, offset + 4096}, {1, offset}});
    const auto & large_tuple = resultTuple(large);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(large_tuple.getColumn(0)).getElement(0), 2);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(large_tuple.getColumn(2)).getElement(0), offset);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(large_tuple.getColumn(3)).getElement(0), offset + 4096);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(large_tuple.getColumn(4)).getElement(0), 0.0);

    /// Equal minima exist at splits 3 and 6.  Independently built
    /// prefix/suffix reductions may differ by an ulp, but the public tie rule
    /// must retain the earliest canonical split.
    const auto repeated_tie = runAggregate(
        "timeSeriesMeanShiftChangePoint", numericParameters({1}), {{0, 0}, {1, 0}, {2, 0}, {3, 1}, {4, 0}, {5, 0}, {6, 1}, {7, 0}, {8, 1}});
    const auto & repeated_tie_tuple = resultTuple(repeated_tie);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(repeated_tie_tuple.getColumn(0)).getElement(0), 3);
    EXPECT_NEAR(assert_cast<const DB::ColumnFloat64 &>(repeated_tie_tuple.getColumn(1)).getElement(0), 0.25, 1e-15);
    EXPECT_NEAR(assert_cast<const DB::ColumnFloat64 &>(repeated_tie_tuple.getColumn(4)).getElement(0), 1.5, 1e-15);

    /// A reverse-Chan subtraction loses this tiny but representable suffix
    /// SSE.  Direct suffix Welford accumulation must preserve 2^-105.
    const Float64 delta = std::ldexp(1., -52);
    const auto cancellation
        = runAggregate("timeSeriesMeanShiftChangePoint", numericParameters({1}), {{0, -1}, {1, -1}, {2, 1}, {3, 1 - delta}});
    const auto & cancellation_tuple = resultTuple(cancellation);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(cancellation_tuple.getColumn(0)).getElement(0), 2);
    EXPECT_DOUBLE_EQ(assert_cast<const DB::ColumnFloat64 &>(cancellation_tuple.getColumn(4)).getElement(0), std::ldexp(1., -105));

    /// The split/score remain valid when a positive original-unit SSE exceeds
    /// Float64.  It is reported honestly as +Inf, not collapsed to zero/NaN.
    constexpr Float64 high = 1e300;
    const auto overflow = runAggregate(
        "timeSeriesMeanShiftChangePoint", numericParameters({1}), {{0, -high}, {1, -high}, {2, high}, {3, std::nextafter(high, 0.)}});
    const auto & overflow_tuple = resultTuple(overflow);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(overflow_tuple.getColumn(0)).getElement(0), 2);
    EXPECT_TRUE(std::isinf(assert_cast<const DB::ColumnFloat64 &>(overflow_tuple.getColumn(4)).getElement(0)));

    /// The only admissible split has exactly the same SSE as the one-mean
    /// model, so there is no identifiable change.
    const auto no_improvement = runAggregate("timeSeriesMeanShiftChangePoint", numericParameters({2}), {{0, 0}, {1, 1}, {2, 1}, {3, 0}});
    const auto & no_improvement_tuple = resultTuple(no_improvement);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(no_improvement_tuple.getColumn(0)).getElement(0), 0);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(no_improvement_tuple.getColumn(1)).getElement(0)));
}

TEST(TimeSeriesStatisticalExtensionsAggregate, DegenerateFinalizersReturnNaN)
{
    const auto constant = std::vector<std::pair<UInt64, Float64>>{{3, 7}, {0, 7}, {2, 7}, {1, 7}};
    const auto regression = runAggregate("timeSeriesLaggedLinearRegression", numericParameters({1}), constant);
    const auto & regression_tuple = resultTuple(regression);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(regression_tuple.getColumn(0)).getElement(0)));

    const auto kpss = runAggregate("timeSeriesKPSSTest", kpssParameters("level", 0), constant);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(resultTuple(kpss).getColumn(0)).getElement(0)));

    const auto change = runAggregate("timeSeriesMeanShiftChangePoint", numericParameters({1}), constant);
    const auto & change_tuple = resultTuple(change);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(change_tuple.getColumn(0)).getElement(0), 0);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(change_tuple.getColumn(1)).getElement(0)));
}

TEST(TimeSeriesStatisticalExtensionsAggregate, InterleavedStateMergeMatchesSinglePassFinalization)
{
    tryRegisterAggregateFunctions();
    const DB::DataTypes arguments{std::make_shared<DB::DataTypeUInt64>(), std::make_shared<DB::DataTypeFloat64>()};
    const DB::Array params = numericParameters({0});
    DB::AggregateFunctionProperties properties;
    auto function
        = DB::AggregateFunctionFactory::instance().get("timeSeriesADFStatistic", DB::NullsAction::EMPTY, arguments, params, properties);
    DB::AlignedBuffer direct(function->sizeOfData(), function->alignOfData());
    DB::AlignedBuffer merged(function->sizeOfData(), function->alignOfData());
    DB::AlignedBuffer rhs(function->sizeOfData(), function->alignOfData());
    function->create(direct.data());
    function->create(merged.data());
    function->create(rhs.data());

    const std::vector<std::pair<UInt64, Float64>> points = {{5, 4}, {0, 1}, {3, 3}, {1, 2}, {4, 2}, {2, 1}};
    auto direct_timestamps = DB::ColumnUInt64::create();
    auto direct_values = DB::ColumnFloat64::create();
    auto left_timestamps = DB::ColumnUInt64::create();
    auto left_values = DB::ColumnFloat64::create();
    auto right_timestamps = DB::ColumnUInt64::create();
    auto right_values = DB::ColumnFloat64::create();
    for (size_t i = 0; i < points.size(); ++i)
    {
        direct_timestamps->getData().push_back(points[i].first);
        direct_values->getData().push_back(points[i].second);
        auto & timestamps = i % 2 ? right_timestamps : left_timestamps;
        auto & values = i % 2 ? right_values : left_values;
        timestamps->getData().push_back(points[i].first);
        values->getData().push_back(points[i].second);
    }
    const DB::IColumn * direct_columns[]{direct_timestamps.get(), direct_values.get()};
    const DB::IColumn * left_columns[]{left_timestamps.get(), left_values.get()};
    const DB::IColumn * right_columns[]{right_timestamps.get(), right_values.get()};
    for (size_t i = 0; i < points.size(); ++i)
        function->add(direct.data(), direct_columns, i, nullptr);
    for (size_t i = 0; i < left_timestamps->size(); ++i)
        function->add(merged.data(), left_columns, i, nullptr);
    for (size_t i = 0; i < right_timestamps->size(); ++i)
        function->add(rhs.data(), right_columns, i, nullptr);
    function->merge(merged.data(), rhs.data(), nullptr);

    auto direct_result = function->getResultType()->createColumn();
    auto merged_result = function->getResultType()->createColumn();
    function->insertResultInto(direct.data(), *direct_result, nullptr);
    function->insertResultInto(merged.data(), *merged_result, nullptr);
    const auto & direct_tuple = resultTuple(direct_result);
    const auto & merged_tuple = resultTuple(merged_result);
    EXPECT_DOUBLE_EQ(
        assert_cast<const DB::ColumnFloat64 &>(direct_tuple.getColumn(0)).getElement(0),
        assert_cast<const DB::ColumnFloat64 &>(merged_tuple.getColumn(0)).getElement(0));
    EXPECT_DOUBLE_EQ(
        assert_cast<const DB::ColumnFloat64 &>(direct_tuple.getColumn(1)).getElement(0),
        assert_cast<const DB::ColumnFloat64 &>(merged_tuple.getColumn(1)).getElement(0));
    EXPECT_EQ(
        assert_cast<const DB::ColumnUInt64 &>(direct_tuple.getColumn(2)).getElement(0),
        assert_cast<const DB::ColumnUInt64 &>(merged_tuple.getColumn(2)).getElement(0));
    function->destroy(direct.data());
    function->destroy(merged.data());
    function->destroy(rhs.data());
}

TEST(TimeSeriesStatisticalExtensionsAggregate, ADFExactFitIsUndefinedButRetainsObservationCount)
{
    /// With no deterministic terms this is an exact y[t] = 2*y[t-1] fit;
    /// zero residual variance makes both the t-statistic and coefficient undefined.
    const auto result = runAggregate("timeSeriesADFStatistic", adfParameters(0, "none"), {{4, 16}, {0, 1}, {3, 8}, {1, 2}, {2, 4}});
    const auto & tuple = resultTuple(result);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(0)).getElement(0)));
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(1)).getElement(0)));
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tuple.getColumn(2)).getElement(0), 4);
}

TEST(TimeSeriesStatisticalExtensionsAggregate, ADFSmallNoisePositiveLagAndTrendAreFinite)
{
    const std::vector<std::pair<UInt64, Float64>> points
        = {{8, 256.1}, {0, 1.0}, {6, 64.2}, {2, 4.1}, {9, 512.0}, {4, 16.3}, {1, 2.0}, {7, 128.0}, {3, 8.2}, {5, 32.1}};

    const auto noisy = runAggregate("timeSeriesADFStatistic", adfParameters(0, "constant"), points);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(resultTuple(noisy).getColumn(0)).getElement(0)));
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(resultTuple(noisy).getColumn(1)).getElement(0)));

    const auto lagged = runAggregate("timeSeriesADFStatistic", adfParameters(1, "constant"), points);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(lagged).getColumn(2)).getElement(0), 8);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(resultTuple(lagged).getColumn(0)).getElement(0)));

    const auto trend = runAggregate("timeSeriesADFStatistic", adfParameters(1, "trend"), points);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(trend).getColumn(2)).getElement(0), 8);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(resultTuple(trend).getColumn(0)).getElement(0)));
}

TEST(TimeSeriesStatisticalExtensionsAggregate, ADFMinimumObservationBoundariesMatchImplementation)
{
    /// The effective finite minima are n=3 (none), n=4 (constant), and n=6
    /// (trend) for these small fixed regressions.
    const auto none = runAggregate("timeSeriesADFStatistic", adfParameters(0, "none"), {{2, 4}, {0, 1}, {1, 2.1}});
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(none).getColumn(2)).getElement(0), 2);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(resultTuple(none).getColumn(0)).getElement(0)));

    const auto constant_too_short = runAggregate("timeSeriesADFStatistic", adfParameters(0, "constant"), {{2, 4}, {0, 1}, {1, 2.1}});
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(constant_too_short).getColumn(2)).getElement(0), 2);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(resultTuple(constant_too_short).getColumn(0)).getElement(0)));

    const auto constant = runAggregate("timeSeriesADFStatistic", adfParameters(0, "constant"), {{3, 8}, {0, 1}, {2, 4.2}, {1, 2.1}});
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(constant).getColumn(2)).getElement(0), 3);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(resultTuple(constant).getColumn(0)).getElement(0)));

    const auto trend_too_short
        = runAggregate("timeSeriesADFStatistic", adfParameters(0, "trend"), {{4, 5}, {0, 1}, {3, 4}, {1, 2}, {2, 3}});
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(trend_too_short).getColumn(2)).getElement(0), 4);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(resultTuple(trend_too_short).getColumn(0)).getElement(0)));
    const auto trend
        = runAggregate("timeSeriesADFStatistic", adfParameters(0, "trend"), {{5, 10.1}, {0, 1}, {3, 6.2}, {1, 2.1}, {4, 8.0}, {2, 4.1}});
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(trend).getColumn(2)).getElement(0), 5);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(resultTuple(trend).getColumn(0)).getElement(0)));

    /// At p=16 the trend design needs enough rows and full-rank deterministic
    /// values.  n=37 is rejected by the fixed-lag admission rule; the
    /// perturbed n=38 fixture supplies an admitted full-rank case.
    std::vector<std::pair<UInt64, Float64>> rank_deficient;
    std::vector<std::pair<UInt64, Float64>> full_rank;
    for (UInt64 i = 0; i < 37; ++i)
        rank_deficient.emplace_back(36 - i, static_cast<Float64>(i + 1));
    for (UInt64 i = 0; i < 38; ++i)
        full_rank.emplace_back(37 - i, static_cast<Float64>((i * i + 3 * i + 7) % 101));
    const auto p16_short = runAggregate("timeSeriesADFStatistic", adfParameters(16, "trend"), rank_deficient);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(resultTuple(p16_short).getColumn(0)).getElement(0)));
    const auto p16_admitted = runAggregate("timeSeriesADFStatistic", adfParameters(16, "trend"), full_rank);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(p16_admitted).getColumn(2)).getElement(0), 21);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(resultTuple(p16_admitted).getColumn(0)).getElement(0)));
}

TEST(TimeSeriesStatisticalExtensionsAggregate, KPSSTrendBandwidthAndDefaultBandwidthBoundaries)
{
    const auto trend
        = runAggregate("timeSeriesKPSSTest", kpssParameters("trend", 1), {{5, 5.2}, {0, 0.1}, {3, 3.0}, {1, 1.2}, {4, 4.1}, {2, 1.8}});
    const auto & trend_tuple = resultTuple(trend);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(trend_tuple.getColumn(1)).getElement(0), 1);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(trend_tuple.getColumn(2)).getElement(0), 6);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(trend_tuple.getColumn(0)).getElement(0)));

    std::vector<std::pair<UInt64, Float64>> n101;
    n101.reserve(101);
    for (UInt64 i = 0; i < 101; ++i)
        n101.emplace_back(100 - i, static_cast<Float64>(i) + (i % 3 == 0 ? 0.1 : 0.));
    const auto automatic = runAggregate("timeSeriesKPSSTest", kpssParameters("level"), n101);
    const auto & automatic_tuple = resultTuple(automatic);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(automatic_tuple.getColumn(1)).getElement(0), 12);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(automatic_tuple.getColumn(2)).getElement(0), 101);
    EXPECT_TRUE(std::isfinite(assert_cast<const DB::ColumnFloat64 &>(automatic_tuple.getColumn(0)).getElement(0)));

    /// For y=[1,2,3,4,5], q=n-1=4 is defined and has the hand-computable
    /// Bartlett statistic 0.5; q=n=5 is rejected by the implementation.
    const std::vector<std::pair<UInt64, Float64>> ramp = {{4, 5}, {0, 1}, {3, 4}, {1, 2}, {2, 3}};
    const auto q_n_minus_1 = runAggregate("timeSeriesKPSSTest", kpssParameters("level", 4), ramp);
    EXPECT_NEAR(assert_cast<const DB::ColumnFloat64 &>(resultTuple(q_n_minus_1).getColumn(0)).getElement(0), 0.5, 1e-14);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(q_n_minus_1).getColumn(1)).getElement(0), 4);
    const auto q_n = runAggregate("timeSeriesKPSSTest", kpssParameters("level", 5), ramp);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(resultTuple(q_n).getColumn(0)).getElement(0)));
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(resultTuple(q_n).getColumn(1)).getElement(0), 5);
}

TEST(TimeSeriesStatisticalExtensionsAggregate, KPSSWorkCapReturnsUndefinedInsteadOfQuadraticWork)
{
    /// HARD_MAX_KPSS_WORK is 100,000,000.  With q=1024, n=100,000 exceeds
    /// the checked n*q budget, so finalization must return NaN without doing
    /// the full Bartlett covariance scan.
    std::vector<std::pair<UInt64, Float64>> points;
    points.reserve(100'000);
    for (UInt64 i = 0; i < 100'000; ++i)
        points.emplace_back(i, static_cast<Float64>(i % 17));
    const auto result = runAggregate("timeSeriesKPSSTest", kpssParameters("level", 1024), points);
    const auto & tuple = resultTuple(result);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(0)).getElement(0)));
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tuple.getColumn(1)).getElement(0), 1024);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tuple.getColumn(2)).getElement(0), 100'000);
}

TEST(TimeSeriesStatisticalExtensionsAggregate, RuntimeMaxSamplesIsForwardedForAllFourFunctions)
{
    const std::vector<std::pair<UInt64, Float64>> points = {{0, 1}, {1, 2}, {2, 3}};
    EXPECT_THROW(runAggregate("timeSeriesLaggedLinearRegression", numericParameters({1, 2}), points), DB::Exception);
    EXPECT_THROW(
        runAggregate(
            "timeSeriesADFStatistic", DB::Array{DB::Field(UInt64{0}), DB::Field(String{"constant"}), DB::Field(UInt64{2})}, points),
        DB::Exception);
    EXPECT_THROW(
        runAggregate("timeSeriesKPSSTest", DB::Array{DB::Field(String{"level"}), DB::Field(UInt64{0}), DB::Field(UInt64{2})}, points),
        DB::Exception);
    EXPECT_THROW(runAggregate("timeSeriesMeanShiftChangePoint", numericParameters({1, 2}), points), DB::Exception);
}

TEST(TimeSeriesStatisticalExtensionsAggregate, RegressionWorkCapsReturnUndefinedBeforeExpensiveQR)
{
    /// order=16 has 256 QR row operations, so 390626 rows are the first value
    /// above the 100,000,000 work budget.  ADF trend has 18 columns and first
    /// exceeds that budget at 308642 post-lag rows.
    std::vector<std::pair<UInt64, Float64>> points;
    points.reserve(390'642);
    for (UInt64 i = 0; i < 390'642; ++i)
        points.emplace_back(i, static_cast<Float64>((i * i + 3 * i + 7) % 101));

    const auto lagged = runAggregate("timeSeriesLaggedLinearRegression", numericParameters({16}), points);
    const auto & lagged_tuple = resultTuple(lagged);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(lagged_tuple.getColumn(0)).getElement(0)));
    const auto & coefficients = assert_cast<const DB::ColumnArray &>(lagged_tuple.getColumn(1));
    ASSERT_EQ(coefficients.getOffsets().back(), 16);
    for (size_t i = 0; i < 16; ++i)
        EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(coefficients.getData()).getElement(i)));

    points.resize(308'659);
    const auto adf = runAggregate("timeSeriesADFStatistic", adfParameters(16, "trend"), points);
    const auto & adf_tuple = resultTuple(adf);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(adf_tuple.getColumn(0)).getElement(0)));
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(adf_tuple.getColumn(1)).getElement(0)));
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(adf_tuple.getColumn(2)).getElement(0), 308'642);
}

TEST(TimeSeriesStatisticalExtensionsAggregate, LongNoImprovementSeriesDoesNotManufactureChange)
{
    /// With min_segment=n/2 there is exactly one admissible split.  The two
    /// halves contain the same alternating sequence, so the two-mean and
    /// one-mean objectives are mathematically equal.  The count-aware
    /// comparison must absorb different prefix/suffix reduction roundoff.
    std::vector<std::pair<UInt64, Float64>> points;
    points.reserve(100'000);
    for (UInt64 i = 0; i < 100'000; ++i)
        points.emplace_back(i, static_cast<Float64>(i % 2));

    const auto result = runAggregate("timeSeriesMeanShiftChangePoint", numericParameters({50'000}), points);
    const auto & tuple = resultTuple(result);
    EXPECT_EQ(assert_cast<const DB::ColumnUInt64 &>(tuple.getColumn(0)).getElement(0), 0);
    EXPECT_TRUE(std::isnan(assert_cast<const DB::ColumnFloat64 &>(tuple.getColumn(1)).getElement(0)));
}
