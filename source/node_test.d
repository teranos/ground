module node_test;

// ground code reads its node's block alone; what it reads is what controls reads with every other block.
import code.node : codeNode = qntxNode;
import builtin_sand : hooksNode = qntxNode;

static assert(codeNode == hooksNode);
