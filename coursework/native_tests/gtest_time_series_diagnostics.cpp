#include <AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesDiagnostics.h>

#include <IO/ReadBufferFromString.h>
#include <IO/WriteBufferFromString.h>
#include <IO/WriteHelpers.h>

#include <gtest/gtest.h>

#include <cmath>
#include <cstddef>
#include <initializer_list>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace
{

using State = DB::TimeSeriesDiagnostics::State<UInt64>;

constexpr UInt64 max_samples = 32;

State makeState(std::initializer_list<std::pair<UInt64, Float64>> points, UInt64 limit = max_samples)
{
    State state;
    for (const auto & [timestamp, value] : points)
        state.add(timestamp, value, limit);
    return state;
}

void expectSamples(const State & state, const std::vector<std::pair<UInt64, Float64>> & expected)
{
    ASSERT_EQ(state.samples.size(), expected.size());
    for (size_t i = 0; i < expected.size(); ++i)
    {
        EXPECT_EQ(state.samples[i].timestamp, expected[i].first);
        EXPECT_DOUBLE_EQ(state.samples[i].value, expected[i].second);
    }
}

std::string
makePayload(UInt16 version, UInt64 serialized_max_samples, UInt64 count, const std::vector<std::pair<UInt64, Float64>> & samples)
{
    DB::WriteBufferFromOwnString output;
    DB::writeBinaryLittleEndian(version, output);
    DB::writeBinaryLittleEndian(serialized_max_samples, output);
    DB::writeBinaryLittleEndian(count, output);
    for (const auto & [timestamp, value] : samples)
    {
        DB::writeBinaryLittleEndian(timestamp, output);
        DB::writeBinaryLittleEndian(value, output);
    }
    return output.str();
}

void expectBadPayload(const std::string & payload, UInt64 expected_max_samples = max_samples)
{
    State restored;
    DB::ReadBufferFromString input(payload);
    EXPECT_THROW(restored.deserialize(input, expected_max_samples), DB::Exception);
}

}

TEST(TimeSeriesDiagnosticsState, ArbitraryAddOrderIsCanonicalized)
{
    State state = makeState({{4, 4}, {1, 1}, {3, 3}, {2, 2}});
    EXPECT_FALSE(state.sorted);

    EXPECT_NEAR(state.autocorrelation(1), 0.25, 1e-15);
    EXPECT_TRUE(state.sorted);
    expectSamples(state, {{1, 1}, {2, 2}, {3, 3}, {4, 4}});
}

TEST(TimeSeriesDiagnosticsState, MergeTreeAndInterleavingAreCanonical)
{
    State leaf_a = makeState({{5, 5}, {1, 1}, {3, 3}});
    State leaf_b = makeState({{6, 6}, {2, 2}, {4, 4}});
    State merged;
    merged.merge(leaf_a, max_samples);
    merged.merge(leaf_b, max_samples);

    State direct = makeState({{6, 6}, {3, 3}, {1, 1}, {5, 5}, {2, 2}, {4, 4}});
    direct.sortAndValidate();
    expectSamples(merged, {{1, 1}, {2, 2}, {3, 3}, {4, 4}, {5, 5}, {6, 6}});
    EXPECT_NEAR(merged.autocorrelation(1), 0.5, 1e-15);
    EXPECT_NEAR(merged.durbinWatson(), direct.durbinWatson(), 1e-15);

    State left = makeState({{1, 1}, {4, 4}});
    State right = makeState({{2, 2}, {3, 3}});
    left.merge(right, max_samples);
    expectSamples(left, {{1, 1}, {2, 2}, {3, 3}, {4, 4}});

    State empty;
    left.merge(empty, max_samples);
    expectSamples(left, {{1, 1}, {2, 2}, {3, 3}, {4, 4}});

    State a = makeState({{4, 5}, {0, 1}});
    State b = makeState({{5, 6}, {1, 2}});
    State c = makeState({{6, 7}, {2, 3}});
    State d = makeState({{7, 8}, {3, 4}});

    State left_deep = a;
    left_deep.merge(b, max_samples);
    left_deep.merge(c, max_samples);
    left_deep.merge(d, max_samples);

    State balanced_left = a;
    balanced_left.merge(b, max_samples);
    State balanced_right = c;
    balanced_right.merge(d, max_samples);
    balanced_left.merge(balanced_right, max_samples);

    State right_deep = c;
    right_deep.merge(d, max_samples);
    State right_middle = b;
    right_middle.merge(right_deep, max_samples);
    State right_tree = a;
    right_tree.merge(right_middle, max_samples);

    expectSamples(left_deep, {{0, 1}, {1, 2}, {2, 3}, {3, 4}, {4, 5}, {5, 6}, {6, 7}, {7, 8}});
    EXPECT_NEAR(left_deep.autocorrelation(2), balanced_left.autocorrelation(2), 1e-15);
    EXPECT_NEAR(left_deep.ljungBoxStatistic(3), right_tree.ljungBoxStatistic(3), 1e-15);
    EXPECT_NEAR(balanced_left.durbinWatson(), right_tree.durbinWatson(), 1e-15);
}

TEST(TimeSeriesDiagnosticsState, DuplicateTimestampsAreRejectedWithinAndAcrossStates)
{
    State within = makeState({{7, 1}, {7, 2}});
    EXPECT_THROW(within.sortAndValidate(), DB::Exception);

    State lhs = makeState({{1, 1}, {3, 3}});
    State rhs = makeState({{2, 2}, {3, 4}});
    EXPECT_THROW(lhs.merge(rhs, max_samples), DB::Exception);
}

TEST(TimeSeriesDiagnosticsState, SampleCapsApplyToAddsAndMerges)
{
    State state;
    state.add(1, 1, 2);
    state.add(2, 2, 2);
    EXPECT_THROW(state.add(3, 3, 2), DB::Exception);

    State lhs = makeState({{1, 1}, {3, 3}}, 2);
    State rhs = makeState({{2, 2}}, 2);
    EXPECT_THROW(lhs.merge(rhs, 2), DB::Exception);
    EXPECT_THROW(lhs.add(4, 4, 0), DB::Exception);
    EXPECT_THROW(lhs.add(4, 4, DB::TimeSeriesDiagnostics::HARD_MAX_SAMPLES + 1), DB::Exception);
}

TEST(TimeSeriesDiagnosticsState, SerializationRoundTripCanonicalizesAndPreservesStatistics)
{
    State source = makeState({{4, 4}, {1, 1}, {3, 3}, {2, 2}});
    DB::WriteBufferFromOwnString output;
    source.serialize(output, max_samples);

    State ordered = makeState({{1, 1}, {2, 2}, {3, 3}, {4, 4}});
    DB::WriteBufferFromOwnString ordered_output;
    ordered.serialize(ordered_output, max_samples);
    EXPECT_EQ(output.str(), ordered_output.str());

    State restored;
    DB::ReadBufferFromString input(output.str());
    ASSERT_NO_THROW(restored.deserialize(input, max_samples));
    EXPECT_TRUE(restored.sorted);
    expectSamples(restored, {{1, 1}, {2, 2}, {3, 3}, {4, 4}});
    EXPECT_NEAR(restored.autocorrelation(1), source.autocorrelation(1), 1e-15);
    EXPECT_NEAR(restored.durbinWatson(), source.durbinWatson(), 1e-15);
}

TEST(TimeSeriesDiagnosticsState, CorruptVersionCountOrderAndNonFinitePayloadsAreRejected)
{
    expectBadPayload(makePayload(2, max_samples, 0, {}));
    expectBadPayload(makePayload(DB::TimeSeriesDiagnostics::SERIALIZATION_VERSION, max_samples, max_samples + 1, {}));
    expectBadPayload(makePayload(DB::TimeSeriesDiagnostics::SERIALIZATION_VERSION, max_samples, 2, {{2, 2}, {1, 1}}));
    expectBadPayload(
        makePayload(DB::TimeSeriesDiagnostics::SERIALIZATION_VERSION, max_samples, 1, {{1, std::numeric_limits<Float64>::quiet_NaN()}}));
}

TEST(TimeSeriesDiagnosticsState, CorruptCapsAndTruncatedPayloadsAreRejected)
{
    const UInt16 version = DB::TimeSeriesDiagnostics::SERIALIZATION_VERSION;
    expectBadPayload(makePayload(version, 0, 0, {}));
    expectBadPayload(makePayload(version, DB::TimeSeriesDiagnostics::HARD_MAX_SAMPLES + 1, 0, {}));
    expectBadPayload(makePayload(version, max_samples, 0, {}), max_samples - 1);
    expectBadPayload(makePayload(version, max_samples, 1, {}));
}

TEST(TimeSeriesDiagnosticsState, DeserializationCrossesBoundedInitialReserve)
{
    constexpr UInt64 sample_count = DB::TimeSeriesDiagnostics::DESERIALIZATION_RESERVE_LIMIT + 1;
    constexpr UInt64 cap = sample_count + 1;
    std::vector<std::pair<UInt64, Float64>> samples;
    samples.reserve(sample_count);
    for (UInt64 timestamp = 0; timestamp < sample_count; ++timestamp)
        samples.emplace_back(timestamp, static_cast<Float64>(timestamp));

    State restored;
    const std::string payload = makePayload(DB::TimeSeriesDiagnostics::SERIALIZATION_VERSION, cap, sample_count, samples);
    DB::ReadBufferFromString input(payload);
    ASSERT_NO_THROW(restored.deserialize(input, cap));
    ASSERT_EQ(restored.samples.size(), sample_count);
    EXPECT_EQ(restored.samples.back().timestamp, sample_count - 1);
}

TEST(TimeSeriesDiagnosticsState, NonFiniteValuesAreRejectedOnAdd)
{
    State state;
    EXPECT_THROW(state.add(1, std::numeric_limits<Float64>::quiet_NaN(), max_samples), DB::Exception);
    EXPECT_THROW(state.add(1, std::numeric_limits<Float64>::infinity(), max_samples), DB::Exception);
    EXPECT_THROW(state.add(1, -std::numeric_limits<Float64>::infinity(), max_samples), DB::Exception);
}

TEST(TimeSeriesDiagnosticsState, AutocorrelationLagZeroTinyAndConstantSeries)
{
    State varying = makeState({{1, 1}, {2, 2}, {3, 3}});
    EXPECT_DOUBLE_EQ(varying.autocorrelation(0), 1.0);

    State empty;
    EXPECT_TRUE(std::isnan(empty.autocorrelation(0)));
    State singleton = makeState({{1, 42}});
    EXPECT_TRUE(std::isnan(singleton.autocorrelation(0)));
    EXPECT_TRUE(std::isnan(singleton.autocorrelation(1)));

    State constant = makeState({{1, 7}, {2, 7}, {3, 7}});
    EXPECT_TRUE(std::isnan(constant.autocorrelation(0)));
    EXPECT_TRUE(std::isnan(constant.autocorrelation(1)));
}

TEST(TimeSeriesDiagnosticsState, AutocorrelationHandlesExtremeValueScales)
{
    for (const Float64 scale : {1e200, 1e-200})
    {
        State state = makeState({{1, -scale}, {2, scale}, {3, -scale}, {4, scale}});
        EXPECT_DOUBLE_EQ(state.autocorrelation(0), 1.0);
        EXPECT_DOUBLE_EQ(state.autocorrelation(1), -0.75);
        EXPECT_DOUBLE_EQ(state.ljungBoxStatistic(1), 4.5);
        EXPECT_DOUBLE_EQ(state.durbinWatson(), 3.0);
    }
}

TEST(TimeSeriesDiagnosticsState, AutocorrelationHandlesLargeValueOffset)
{
    constexpr Float64 offset = 1e12;
    State state = makeState({{4, offset + 4}, {1, offset + 1}, {3, offset + 3}, {2, offset + 2}});
    EXPECT_NEAR(state.autocorrelation(1), 0.25, 1e-10);
}

TEST(TimeSeriesDiagnosticsState, LargeOffsetRetainsRepresentableVariation)
{
    constexpr Float64 offset = 1e16;
    constexpr Float64 step = 4096;
    State state = makeState({{4, offset + 4 * step}, {1, offset + step}, {3, offset + 3 * step}, {2, offset + 2 * step}});

    EXPECT_NEAR(state.autocorrelation(1), 0.25, 1e-12);
}

TEST(TimeSeriesDiagnosticsState, LjungBoxStatisticUsesRequestedLags)
{
    State state = makeState({{4, 4}, {1, 1}, {3, 3}, {2, 2}});
    EXPECT_NEAR(state.ljungBoxStatistic(1), 0.5, 1e-14);
    EXPECT_NEAR(state.ljungBoxStatistic(2), 1.58, 1e-14);
    EXPECT_TRUE(std::isnan(state.ljungBoxStatistic(0)));
    EXPECT_TRUE(std::isnan(state.ljungBoxStatistic(4)));
}

TEST(TimeSeriesDiagnosticsState, DurbinWatsonUsesTimestampOrder)
{
    State state = makeState({{4, 4}, {1, 1}, {3, 3}, {2, 2}});
    EXPECT_NEAR(state.durbinWatson(), 0.1, 1e-15);

    State singleton = makeState({{1, 2}});
    EXPECT_TRUE(std::isnan(singleton.durbinWatson()));
    State zero = makeState({{1, 0}, {2, 0}});
    EXPECT_TRUE(std::isnan(zero.durbinWatson()));
}
