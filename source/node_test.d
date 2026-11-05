module node_test;

// 「[Opus 5.5] ground code reads its node's block alone; what it reads is what controls reads with every other block.」
import code.node : codeNode = qntxNode;
import sand.builtin : hooksNode = qntxNode;

static assert(codeNode == hooksNode);
