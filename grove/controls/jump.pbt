rites rites1 {
  WAIT1       { run: "sleep 7" }
  TRAMPOLINE1 { goto: END }
  HEDGE1 { }
  HEDGE2 { }
  HEDGE3 { }
  END { }
}

rites rites2 {
  WAIT2       { run: "sleep 7" }
  TRAMPOLINE2 { goto: END }
  HEDGE4 { }
  HEDGE5 { }
  HEDGE6 { }
  END { }
}

project {
  path: "/teranos/ground"

  ritual jump {
    tree: "checkout"
    rites1
    rites2
  }
}
