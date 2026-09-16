#pragma once

#include <AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesDiagnostics.h>

#include <Common/Exception.h>

namespace DB::ErrorCodes
{
extern const int INCORRECT_DATA;
}

namespace DB::TimeSeriesStatisticalExtensions
{

/// This envelope deliberately contains only identity/configuration data.  The
/// payload remains the exact keyed state used by the diagnostics aggregates:
/// a compact summary cannot reconstruct lagged rows after arbitrary shard
/// interleaving.
inline constexpr UInt16 SERIALIZATION_VERSION = 1;

enum class Kind : UInt8
{
    LaggedLinearRegression = 1,
    ADFStatistic = 2,
    KPSSTest = 3,
    MeanShiftChangePoint = 4,
};

struct Parameters
{
    Kind kind{};
    UInt64 first = 0;
    UInt64 second = 0;
    UInt64 third = 0;
    UInt64 max_samples = TimeSeriesDiagnostics::DEFAULT_MAX_SAMPLES;

    bool operator==(const Parameters &) const = default;
};

template <typename Timestamp>
struct KeyedState
{
    using SamplesState = TimeSeriesDiagnostics::State<Timestamp>;

    SamplesState samples;

    void add(Timestamp timestamp, Float64 value, UInt64 max_samples) { samples.add(timestamp, value, max_samples); }

    void merge(const KeyedState & rhs, UInt64 max_samples) { samples.merge(rhs.samples, max_samples); }

    void sortAndValidate() { samples.sortAndValidate(); }

    void serialize(WriteBuffer & buffer, const Parameters & parameters) const
    {
        /// The envelope identifies the statistical finalizer. The delegated
        /// keyed-state payload intentionally retains its own independent
        /// format version and max-sample guard.
        writeBinaryLittleEndian(SERIALIZATION_VERSION, buffer);
        writeBinaryLittleEndian(static_cast<UInt8>(parameters.kind), buffer);
        writeBinaryLittleEndian(parameters.first, buffer);
        writeBinaryLittleEndian(parameters.second, buffer);
        writeBinaryLittleEndian(parameters.third, buffer);
        writeBinaryLittleEndian(parameters.max_samples, buffer);
        samples.serialize(buffer, parameters.max_samples);
    }

    void deserialize(ReadBuffer & buffer, const Parameters & expected)
    {
        UInt16 version = 0;
        UInt8 kind = 0;
        Parameters actual;
        readBinaryLittleEndian(version, buffer);
        if (version != SERIALIZATION_VERSION)
            throw Exception(ErrorCodes::INCORRECT_DATA, "Unsupported time-series statistical extension state version {}", version);

        /// Only parse the current version's envelope after the version has
        /// been accepted.  A future version may use a different field layout.
        readBinaryLittleEndian(kind, buffer);
        readBinaryLittleEndian(actual.first, buffer);
        readBinaryLittleEndian(actual.second, buffer);
        readBinaryLittleEndian(actual.third, buffer);
        readBinaryLittleEndian(actual.max_samples, buffer);
        if (kind < static_cast<UInt8>(Kind::LaggedLinearRegression) || kind > static_cast<UInt8>(Kind::MeanShiftChangePoint))
            throw Exception(
                ErrorCodes::INCORRECT_DATA, "Unknown time-series statistical extension state kind {}", static_cast<UInt64>(kind));
        actual.kind = static_cast<Kind>(kind);

        if (!(actual == expected))
            throw Exception(
                ErrorCodes::INCORRECT_DATA,
                "Incompatible time-series statistical extension state (kind {}, parameters do not match)",
                static_cast<UInt64>(kind));

        samples.deserialize(buffer, expected.max_samples);
    }
};

}
