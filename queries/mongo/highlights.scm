(comment) @comment @spell

(pair
  key: (string) @property)

(string) @string
(escape_sequence) @string.escape
(number) @number
[
  (true)
  (false)
] @boolean
(null) @constant.builtin

; The command object's own keys are structural: the operation names the
; collection it targets, "db" the database, the rest are its arguments.
(statement
  (object
    (pair
      key: (string (string_content) @keyword.function)
      (#any-of? @keyword.function
        "find" "aggregate"
        "insertOne" "insertMany"
        "updateOne" "updateMany"
        "deleteOne" "deleteMany"
        "createCollection" "dropCollection"
        "createIndex" "dropIndex"))))

(statement
  (object
    (pair
      key: (string (string_content) @keyword)
      (#any-of? @keyword
        "db" "filter" "projection" "sort" "limit" "pipeline"
        "document" "documents" "update" "keys" "options" "name"))))

; Query, update and aggregation operators: `$eq`, `$set`, `$group`, …
((pair
  key: (string (string_content) @function.builtin))
  (#match? @function.builtin "^\\$"))

; Extended JSON type wrappers: `{"$oid": …}`, `{"$date": …}`.
((pair
  key: (string (string_content) @type.builtin))
  (#any-of? @type.builtin
    "$oid" "$date" "$numberInt" "$numberLong" "$numberDouble" "$numberDecimal"
    "$binary" "$regularExpression" "$timestamp" "$uuid" "$minKey" "$maxKey"
    "$symbol" "$code" "$scope" "$dbPointer" "$undefined"))

; A field reference in an aggregation expression, `{"_id": "$status"}`.
((pair
  value: (string (string_content) @variable.member))
  (#match? @variable.member "^\\$[^$]"))

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
