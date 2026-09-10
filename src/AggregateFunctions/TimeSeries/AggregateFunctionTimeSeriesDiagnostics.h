#pragma once

#include <Core/Types.h>
#include <IO/ReadHelpers.h>
#include <IO/WriteHelpers.h>
#include <Common/Exception.h>
#include <Common/VectorWithMemoryTracking.h>

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>

namespace DB
{

namespace ErrorCodes
{
extern const int BAD_ARGUMENTS;
extern const int INCORRECT_DATA;
}

namespace TimeSeriesDiagnostics
{

inline constexpr UInt16 SERIALIZATION_VERSION = 1;
inline constexpr UInt64 DEFAULT_MAX_SAMPLES = 1'000'000;
inline constexpr UInt64 HARD_MAX_SAMPLES = 10'000'000;
inline constexpr UInt64 HARD_MAX_LAG = 10'000;
inline constexpr UInt64 DESERIALIZATION_RESERVE_LIMIT = 4096;

template <typename Timestamp>
struct Sample
{
    Timestamp timestamp{};
    Float64 value = 0;
};

/// Neumaier compensation is robust when an update is larger than the running sum.
struct CompensatedSum
{
    Float64 sum = 0;
    Float64 compensation = 0;

    void add(Float64 value)
    {
        const Float64 updated = sum + value;
        if (std::abs(sum) >= std::abs(value))
            compensation += (sum - updated) + value;
        else
            compensation += (value - updated) + sum;
        sum = updated;
    }

    Float64 result() const { return sum + compensation; }
};

struct CenteredMoments
{
    Float64 location = 0;
    Float64 scale = 0;
    Float64 mean_scaled = 0;
    Float64 m2_scaled = 0;

    Float64 centeredScaled(Float64 value) const { return (value - location) / scale - mean_scaled; }
};

template <typename Timestamp>
struct State
{
    using SampleType = Sample<Timestamp>;
    using Samples = VectorWithMemoryTracking<SampleType>;
    Samples samples;
    bool sorted = true;

    static bool lessByTimestamp(const SampleType & lhs, const SampleType & rhs) { return lhs.timestamp < rhs.timestamp; }

    void add(Timestamp timestamp, Float64 value, UInt64 max_samples)
    {
        validateLimit(max_samples);
        if (!std::isfinite(value))
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "Time-series diagnostics require finite values");

        if (samples.size() >= max_samples)
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "Time-series aggregate state exceeds max_samples={}", max_samples);

        const bool out_of_order = !samples.empty() && timestamp <= samples.back().timestamp;
        samples.push_back(SampleType{.timestamp = timestamp, .value = value});
        if (out_of_order)
            sorted = false;
    }

    void sortAndValidate()
    {
        if (!sorted)
        {
            std::sort(samples.begin(), samples.end(), lessByTimestamp);
            sorted = true;
        }

        validateUnique();
    }

    void validateUnique() const
    {
        for (size_t i = 1; i < samples.size(); ++i)
        {
            if (samples[i - 1].timestamp == samples[i].timestamp)
                throw Exception(ErrorCodes::BAD_ARGUMENTS, "Duplicate time-series timestamp");
        }
    }

    /// Canonicalization sorts each unsorted input once; the subsequent two-pointer merge is linear.
    void merge(const State & rhs, UInt64 max_samples)
    {
        validateLimit(max_samples);
        if (rhs.samples.size() > max_samples || samples.size() > max_samples - rhs.samples.size())
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "Merged time-series aggregate state exceeds max_samples={}", max_samples);

        const Samples * rhs_samples = &rhs.samples;
        State sorted_rhs;
        if (!rhs.sorted)
        {
            sorted_rhs = rhs;
            sorted_rhs.sortAndValidate();
            rhs_samples = &sorted_rhs.samples;
        }
        else
        {
            rhs.validateUnique();
        }
        sortAndValidate();

        Samples merged;
        merged.reserve(samples.size() + rhs.samples.size());
        size_t left = 0;
        size_t right = 0;
        while (left < samples.size() && right < rhs_samples->size())
        {
            if (samples[left].timestamp < (*rhs_samples)[right].timestamp)
                merged.push_back(samples[left++]);
            else if ((*rhs_samples)[right].timestamp < samples[left].timestamp)
                merged.push_back((*rhs_samples)[right++]);
            else
                throw Exception(ErrorCodes::BAD_ARGUMENTS, "Duplicate time-series timestamp while merging aggregate states");
        }
        merged.insert(merged.end(), samples.begin() + left, samples.end());
        merged.insert(merged.end(), rhs_samples->begin() + right, rhs_samples->end());
        samples.swap(merged);
        sorted = true;
    }

    CenteredMoments moments() const
    {
        CenteredMoments result;
        if (samples.empty())
            return result;

        Float64 minimum = samples.front().value;
        Float64 maximum = samples.front().value;
        for (const auto & sample : samples)
        {
            minimum = std::min(minimum, sample.value);
            maximum = std::max(maximum, sample.value);
        }

        result.location = std::midpoint(minimum, maximum);
        result.scale = std::max(std::abs(minimum - result.location), std::abs(maximum - result.location));
        if (!(result.scale > 0))
            return result;

        CompensatedSum scaled_sum;
        for (const auto & sample : samples)
            scaled_sum.add((sample.value - result.location) / result.scale);
        result.mean_scaled = scaled_sum.result() / static_cast<Float64>(samples.size());

        CompensatedSum m2;
        for (const auto & sample : samples)
        {
            const Float64 centered = result.centeredScaled(sample.value);
            m2.add(centered * centered);
        }
        result.m2_scaled = m2.result();
        return result;
    }

    Float64 autocorrelation(UInt64 lag)
    {
        sortAndValidate();
        const CenteredMoments centered = moments();
        return autocorrelationCanonical(lag, centered);
    }

    Float64 ljungBoxStatistic(UInt64 max_lag)
    {
        sortAndValidate();
        if (!max_lag || samples.size() <= max_lag)
            return nan();

        const CenteredMoments centered = moments();
        if (!(centered.m2_scaled > 0))
            return nan();

        CompensatedSum terms;
        for (UInt64 lag = 1; lag <= max_lag; ++lag)
        {
            const Float64 rho = autocorrelationCanonical(lag, centered);
            if (!std::isfinite(rho))
                return nan();
            terms.add(rho * rho / static_cast<Float64>(samples.size() - lag));
        }

        const Float64 n = static_cast<Float64>(samples.size());
        return n * (n + 2) * terms.result();
    }

    Float64 durbinWatson()
    {
        sortAndValidate();
        if (samples.size() < 2)
            return nan();

        Float64 scale = 0;
        for (const auto & sample : samples)
            scale = std::max(scale, std::abs(sample.value));
        if (!(scale > 0))
            return nan();

        CompensatedSum numerator;
        CompensatedSum denominator;
        Float64 previous = samples.front().value / scale;
        denominator.add(previous * previous);
        for (size_t i = 1; i < samples.size(); ++i)
        {
            const Float64 current = samples[i].value / scale;
            const Float64 difference = current - previous;
            numerator.add(difference * difference);
            denominator.add(current * current);
            previous = current;
        }
        if (!(denominator.result() > 0))
            return nan();
        return numerator.result() / denominator.result();
    }

    void serialize(WriteBuffer & buffer, UInt64 max_samples) const
    {
        validateLimit(max_samples);
        if (samples.size() > max_samples)
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "Time-series aggregate state exceeds max_samples={}", max_samples);

        if (!sorted)
        {
            State canonical = *this;
            canonical.sortAndValidate();
            canonical.serializeCanonical(buffer, max_samples);
            return;
        }

        validateUnique();
        serializeCanonical(buffer, max_samples);
    }

    void serializeCanonical(WriteBuffer & buffer, UInt64 max_samples) const
    {
        validateLimit(max_samples);
        if (samples.size() > max_samples)
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "Time-series aggregate state exceeds max_samples={}", max_samples);

        writeBinaryLittleEndian(SERIALIZATION_VERSION, buffer);
        writeBinaryLittleEndian(max_samples, buffer);
        writeBinaryLittleEndian(static_cast<UInt64>(samples.size()), buffer);
        for (const auto & sample : samples)
        {
            writeBinaryLittleEndian(sample.timestamp, buffer);
            writeBinaryLittleEndian(sample.value, buffer);
        }
    }

    void deserialize(ReadBuffer & buffer, UInt64 expected_max_samples)
    {
        validateLimit(expected_max_samples);

        UInt16 format_version = 0;
        readBinaryLittleEndian(format_version, buffer);
        if (format_version != SERIALIZATION_VERSION)
            throw Exception(
                ErrorCodes::INCORRECT_DATA,
                "Unsupported time-series diagnostic state version {} (expected {})",
                format_version,
                SERIALIZATION_VERSION);

        UInt64 serialized_max_samples = 0;
        readBinaryLittleEndian(serialized_max_samples, buffer);
        if (serialized_max_samples != expected_max_samples || !serialized_max_samples || serialized_max_samples > HARD_MAX_SAMPLES)
            throw Exception(
                ErrorCodes::INCORRECT_DATA,
                "Serialized max_samples={} does not match expected max_samples={}",
                serialized_max_samples,
                expected_max_samples);

        UInt64 serialized_size = 0;
        readBinaryLittleEndian(serialized_size, buffer);
        if (serialized_size > serialized_max_samples || serialized_size > HARD_MAX_SAMPLES)
            throw Exception(
                ErrorCodes::INCORRECT_DATA,
                "Serialized time-series sample count {} exceeds max_samples={}",
                serialized_size,
                serialized_max_samples);

        Samples decoded;
        /// A truncated/corrupt payload cannot force allocation of the entire claimed size upfront.
        decoded.reserve(static_cast<size_t>(std::min(serialized_size, DESERIALIZATION_RESERVE_LIMIT)));
        for (UInt64 i = 0; i < serialized_size; ++i)
        {
            SampleType sample;
            readBinaryLittleEndian(sample.timestamp, buffer);
            readBinaryLittleEndian(sample.value, buffer);
            if (!std::isfinite(sample.value))
                throw Exception(ErrorCodes::INCORRECT_DATA, "Non-finite value in serialized time-series diagnostic state");
            if (!decoded.empty() && !(decoded.back().timestamp < sample.timestamp))
                throw Exception(ErrorCodes::INCORRECT_DATA, "Serialized time-series timestamps are not strictly increasing");
            decoded.push_back(sample);
        }
        samples.swap(decoded);
        sorted = true;
    }

private:
    Float64 autocorrelationCanonical(UInt64 lag, const CenteredMoments & centered) const
    {
        if (samples.size() <= lag || !(centered.m2_scaled > 0))
            return nan();
        if (!lag)
            return 1;

        CompensatedSum covariance;
        for (size_t i = lag; i < samples.size(); ++i)
        {
            covariance.add(centered.centeredScaled(samples[i].value) * centered.centeredScaled(samples[i - lag].value));
        }
        return covariance.result() / centered.m2_scaled;
    }

    static Float64 nan() { return std::numeric_limits<Float64>::quiet_NaN(); }

    static void validateLimit(UInt64 max_samples)
    {
        if (!max_samples || max_samples > HARD_MAX_SAMPLES)
            throw Exception(ErrorCodes::BAD_ARGUMENTS, "max_samples must be in [1, {}], got {}", HARD_MAX_SAMPLES, max_samples);
    }
};

}
}
