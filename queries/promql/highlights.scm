(comment) @comment

(string_literal) @string
(escape_sequence) @string.escape

(number_literal) @number
(duration) @number

(metric_identifier) @variable
(label_name) @property

(match_op) @operator
[
  "+"
  "-"
  "*"
  "/"
  "%"
  "^"
  "=="
  "!="
  "<="
  "<"
  ">="
  ">"
] @operator

(aggr_op) @keyword
(bool_modifier) @keyword.operator
[
  "by"
  "without"
  "on"
  "ignoring"
  "group_left"
  "group_right"
  "offset"
  "and"
  "or"
  "unless"
  "atan2"
  "@"
] @keyword.operator

[
  "start"
  "end"
] @function.builtin

(call_expr function: (identifier) @function)

[
  "("
  ")"
  "{"
  "}"
  "["
  "]"
] @punctuation.bracket

[
  ","
  ":"
] @punctuation.delimiter
