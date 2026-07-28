# Ground commit grammar.
#
#   THING: what was done, <= 80
#   up to two more opening lines, <= 80 each
#
#   subthing: what it is, <= 80
#   continuation, <= 80
#   ...up to 4 lines per subthing, up to 5 subthings
#
# THING is ALLCAPS and may carry underscores and digits — THING, THING_,
# THING_ONE, THING_1. It names the one whole thing this commit does.
#
# Every line is bounded by line(max: 80), which measures the whole line rather
# than the tail after the tag, so a long tag cannot buy extra width.
#
# notahead[ newline() ] is what stops a block at its blank separator, and
# notahead[ lower(1..20) literal(": ") ] is what stops a subthing's
# continuations at the next subthing. repeat is greedy with no backtracking,
# so without those guards line(max: 80) — which matches ANY line — would
# swallow the rest of the message.
#
# end() closes the document. Matching is anchored at position 0 and trailing
# content is otherwise allowed, so without it a malformed body would be
# indistinguishable from "the rest of the string, which we permit".
#
# The message must arrive on -m. -F and editor messages are denied: the value
# would be a path, not the text, and unchecked is not accepted.
scope {
  path: "/teranos/ground"
  event: "PreToolUse"

  control {
    name: "ground-commit-format"
    cmd: "git commit"

    strop {
      flag: "-m"
      sequence [
        letters(1..20)
        repeat(0..3)[ literal("_") letters(0..20) digits(0..4) ]
        literal(": ")
        line(max: 80)

        repeat(0..1)[
          newline()
          repeat(0..2)[ notahead[ newline() ] line(max: 80) newline() ]

          repeat(0..1)[
            newline()
            repeat(0..5)[
              lower(1..20)
              repeat(0..3)[ oneof(["-", "_"]) lower(0..20) digits(0..4) ]
              literal(": ")
              line(max: 80)
              newline()
              repeat(0..3)[
                notahead[ newline() ]
                notahead[ lower(1..20) literal(": ") ]
                line(max: 80)
                newline()
              ]
              repeat(0..1)[ newline() ]
            ]
          ]
        ]

        end()
      ]
    }
  }
}
