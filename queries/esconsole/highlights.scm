; Later patterns win over earlier ones for the same node, so the generic
; captures come first and the more specific ones refine them.

(comment) @comment @spell

; ── Request line ────────────────────────────────────────────────────────────

(method) @keyword

(path
  (segment) @module)

; Endpoints — `_search`, `_cat`, `_doc` — start with an underscore; index
; names cannot.
((segment) @function.builtin
  (#match? @function.builtin "^_"))

(param_name) @property

(param_value) @string

(path
  [
    "/"
  ] @punctuation.delimiter)

(query_string
  [
    "?"
    "&"
  ] @punctuation.delimiter)

(query_param
  "=" @operator)

; ── Body ────────────────────────────────────────────────────────────────────

(string) @string

(pair
  key: (string) @property)

(escape_sequence) @string.escape

(number) @number

[
  (true)
  (false)
] @boolean

(null) @constant.builtin

; Query DSL, aggregation and request-body keywords.
(pair
  key: (string
    (string_content) @keyword)
  (#any-of? @keyword
    ; search body
    "query" "aggs" "aggregations" "size" "from" "sort" "_source" "fields"
    "highlight" "post_filter" "track_total_hits" "search_after" "collapse"
    "script" "script_fields" "runtime_mappings" "knn" "suggest" "rescore"
    "min_score" "timeout" "pit" "stored_fields" "docvalue_fields" "explain"
    ; compound queries
    "bool" "must" "must_not" "should" "filter" "minimum_should_match" "boost"
    "constant_score" "dis_max" "function_score" "script_score" "boosting"
    "positive" "negative" "negative_boost" "functions" "queries"
    ; leaf queries
    "match" "match_all" "match_none" "match_phrase" "match_phrase_prefix"
    "match_bool_prefix" "multi_match" "query_string" "simple_query_string"
    "combined_fields" "intervals" "term" "terms" "terms_set" "range" "exists"
    "prefix" "wildcard" "regexp" "fuzzy" "ids" "nested" "has_child"
    "has_parent" "parent_id" "geo_distance" "geo_bounding_box" "geo_shape"
    "more_like_this" "percolate" "rank_feature" "distance_feature" "pinned"
    ; aggregations
    "avg" "sum" "min" "max" "cardinality" "value_count" "stats"
    "extended_stats" "percentiles" "percentile_ranks" "top_hits" "top_metrics"
    "date_histogram" "histogram" "auto_date_histogram" "date_range"
    "composite" "filters" "significant_terms" "rare_terms" "multi_terms"
    "bucket_sort" "bucket_selector" "bucket_script" "cumulative_sum"
    "derivative" "moving_fn" "reverse_nested" "global" "missing" "sampler"
    ; index management and documents
    "mappings" "settings" "properties" "aliases" "dynamic" "doc" "upsert"
    "doc_as_upsert" "index" "create" "update" "delete"))

; Range bounds.
(pair
  key: (string
    (string_content) @keyword.operator)
  (#any-of? @keyword.operator "gt" "gte" "lt" "lte"))

; The key a leaf query, a sort clause or a mapping is keyed by is a field.
(pair
  key: (string
    (string_content) @_parent)
  value: (object
    (pair
      key: (string
        (string_content) @variable.member)))
  (#any-of? @_parent
    "match" "match_phrase" "match_phrase_prefix" "match_bool_prefix" "term"
    "terms" "terms_set" "range" "prefix" "wildcard" "regexp" "fuzzy"
    "intervals" "geo_distance" "geo_bounding_box" "geo_shape" "properties"))

(pair
  key: (string
    (string_content) @_parent)
  value: (array
    (object
      (pair
        key: (string
          (string_content) @variable.member))))
  (#eq? @_parent "sort"))

; A value naming a field: `"field": "price"`, `"fields": ["a", "b"]`.
(pair
  key: (string
    (string_content) @_key)
  value: (string
    (string_content) @variable.member)
  (#any-of? @_key "field" "path" "default_field"))

(pair
  key: (string
    (string_content) @_key)
  value: (array
    (string
      (string_content) @variable.member))
  (#any-of? @_key "fields" "_source"))

; ── Parameters, last so they stand out of the string or path they sit in ──

(parameter) @variable.parameter

[
  ","
  ":"
] @punctuation.delimiter

[
  "{"
  "}"
  "["
  "]"
] @punctuation.bracket
