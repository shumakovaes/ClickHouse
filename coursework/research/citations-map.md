# Citation map

| Claim | Cite |
|---|---|
| Stable one-pass mean/variance update | `welford1962`; `chan1983` |
| Associative pairwise/parallel merge of `(n, mean, M2)` | `chan1982`; `chan1983` |
| Covariance and higher-moment merge formulas | `pebay2008`; `pebay2015` |
| Box–Pierce residual portmanteau diagnostic | `boxpierce1970` |
| Ljung–Box finite-sample improvement and residual lack-of-fit test | `ljungbox1978` |
| Durbin–Watson first-order residual serial-correlation statistic | `durbinwatson1950`; `durbinwatson1971` |
| Classical autoregressive lag-equation framework; OLS as lagged regression | `yule1927` |
| KPSS stationarity null and long-run variance/LM test | `kpss1992` |
| HAC/Newey–West covariance estimator | `neweywest1987` |
| ClickHouse columnar OLAP architecture and MergeTree design | `schulze2024clickhouse` |
| MergeTree inserts create parts; sorting is per part by ORDER BY/primary key; sparse marks/granules; background merges | `clickhouse_mergetree_docs`; `clickhouse_parts_docs` |
| ORDER BY affects physical order/indexing and should not be treated as a globally materialized stream order | `clickhouse_mergetree_docs`; `clickhouse_schema_docs`; `clickhouse_streaming_issue` |
| External sort can be represented as sorted runs followed by deterministic multiway merging; replacement selection improves run generation | `larsongraefe1998`; `larson2003` |
| Associative/distributive aggregate states enable parallel roll-up and merge-based aggregation | `gray1997datacube`; `chan1982`; `pebay2008` |
| `timeSeriesGroupArray` sorts `(timestamp,value)` pairs ascending and retains the greatest value for duplicate timestamps | `clickhouse_timeseriesgrouparray_docs`; `clickhouse_timeseriesgrouparray_source` |
| Official ClickHouse intern-task reference for issue #87836 | `clickhouse_issue87836` |

The ClickHouse issue is included as an official implementation/RFC reference, not as a peer-reviewed source. “Yule (1927)” is the historical AR reference; exact finite-sample OLS properties should be stated as standard regression results rather than attributed solely to Yule.

The `timeSeriesGroupArray` source is especially useful for implementation semantics: the aggregate state appends samples during `add`/`merge`, then sorts and deduplicates on finalization; this is distinct from claiming that input rows arrive globally ordered.
