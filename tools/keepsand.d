/// keepsand <this tree's .ctfe/sand.projects> <the installed sand>
/// Exits 1, saying why, when make install would put the floor where the machine's sand is.
module keepsand;

import keep : refusal, projectsOf, countRefusal;

int main(string[] args) {
    import std.file : exists, readText;
    import std.stdio : stderr;
    if (args.length != 3) {
        stderr.writeln("usage: keepsand <.ctfe/sand.projects> <installed sand>");
        return 2;
    }
    if (!exists(args[1])) {
        stderr.writeln("keepsand: ", args[1], " is not there: wind writes it beside .ctfe/sand");
        return 2;
    }
    auto folded = projectsOf(readText(args[1]));
    if (folded < 0) {
        stderr.writeln("keepsand: ", args[1], " holds no count of projects");
        return 2;
    }
    auto side = args[2] ~ ".projects";
    auto counted = exists(side);
    auto countText = counted ? readText(side) : "";
    auto why = countRefusal(counted, countText, args[2]);
    if (why.length == 0) why = refusal(exists(args[2]), counted ? projectsOf(countText) : -1, folded, args[2]);
    if (why.length == 0) return 0;
    stderr.writeln(why);
    return 1;
}
