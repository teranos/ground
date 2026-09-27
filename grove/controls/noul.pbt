# Jev's three primitives as rites. `ground ritual jev` performs it here: the
# state is this tree's last commit, as git tells it. Without ~/.qntx/jev-token
# every Jev rite advances on its own and says so.

rites judged {
  ROUTE {
    choice: "Which rite should this push go to next?"
    criteria {
      IMPACT: "The push changes code that runs: a source file, a build, a schema"
      DONE:   "The push changes only words: documentation, comments, a book"
    }
    to: parent
  }

  IMPACT {
    score: "What would installing this push change on the running system?"
    criteria: [
      "Nothing a running process would notice: tests, comments, log wording, documentation",
      "What is printed or shown differs; what is decided does not",
      "A hook or sky decides differently on the same input",
      "The store is read or written differently: a table, a column, a query",
      "What a session is allowed to do changes: a control, a permission, a deny"
    ]
    goto: DONE
    to:   parent
  }

  NEEDED {
    noul: "This push is consequential and wants to be installed under running sessions"
    to:   parent
  }

  DONE {
    mic: "Judged. The rows above hold what Jev answered, as Jev sent it."
    to:  parent
  }
}

project {
  path: "/teranos/ground"

  ritual jev {
    tree: "checkout"
    system: "You are here to watch rites be judged by Jev instead of by commands. You do nothing to the tree. Each turn, say which rite the performance is on and what Jev answered."
    judged
  }
}
