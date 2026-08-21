# 1. Did the user ever say what i put in quotation marks?

# "the control needs to block you from putting ANYTHING in quotes in comments or documentation if it was not found in verbatim text i typed."

# > Quotation marks assert provenance, so ground checks the assertion against
# > what the user typed. Verbatim or it is not a quote. The write is denied,
# > and the denial names the span that had no source.

# "Let’s say I want to allow claude to correct my quote minorly."

# "Like allowing it to change up to 4 chars per 40 chars but never more."

# "And a passing warn at 5 and 6"

# > Verbatim first. Failing that, a span may sit within the correction budget
# > of a recorded prompt: four characters changed, dropped, or added per forty
# > the span carries, floored. A span under ten characters buys no
# > corrections. Five or six per forty still passes, but as a warning rather
# > than in silence; past six the span does not pass at all.

# 2. Does the quote stand on its own line?

# "you cannot place your word next to mine"

# "if you quote me, my quote occupies the entire line,"

# > A line carrying a quote carries nothing else, because commentary beside a
# > quote reads as part of it. Whitespace before the opening mark, whitespace
# > after the closing mark, and in a comment the line begins after the marker.

# 3. Do the quotes appear in the order they were said?

# "if you quoe me with a quote of yourself as well, it either goes above my quote because its something i responded to or under my quote because you responded to me."

# "and it also needs to be able to judge you got the chronology right, you arent allowed to have an interpretation of that either, things happen in particular chronology and it matters to me."

# > Two sourced quotes in the wrong order tell a story neither of them told.
# > Ground knows when each was said, so the order is measured, not judged.

scope {
  event: "PreToolUse"
  decision: "deny"

  control {
    name: "quotes-deserve-provenance"
    check_handler: "quoteProvenance"
    msg: "A quoted span has no match in what the user typed."
  }

  control {
    name: "quotes-stand-alone"
    check_handler: "quoteStandsAlone"
    msg: "A quoted span shares its line with other text."
  }

  control {
    name: "quotes-keep-chronology"
    check_handler: "quoteChronology"
    msg: "Quoted spans appear in a different order than they were said."
  }
}

# No decision: the control injects context and the write proceeds. The span
# passed provenance on five or six corrections per forty, which is more than
# a minor correction spends, and the warning says so.

scope {
  event: "PreToolUse"

  control {
    name: "quotes-stretched-thin"
    check_handler: "quoteProvenanceStretched"
    msg: "A quoted span spent more than a minor correction to pass."
  }
}
