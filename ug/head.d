module head;

// The statushead: the one line that has not changed across three
// implementations of it. Everything it draws is gathered here and formatted
// in row.d, so what it says and how it looks stay separable.

import core.stdc.stdio : stdout, fwrite, fputs;
import core.stdc.time : time_t, localtime;

import row : rowOneInto, Head;
import json : jsonString, jsonNumber;
import git : readHead, branchOf, readPorcelain;
import status : countPorcelain;

void statushead(const(char)[] input, time_t now) {
    auto lt = localtime(&now);

    import core.stdc.stdlib : getenv;

    Head h;
    h.cwd = jsonString(input, "cwd");
    h.projectDir = jsonString(input, "project_dir");
    h.style = jsonString(input, "name");

    auto home = getenv("HOME\0".ptr);
    if (home !is null) {
        size_t n = 0;
        while (home[n] != 0) n++;
        h.home = home[0 .. n];
    }

    h.branch = branchOf(readHead(h.cwd));
    h.model = jsonString(input, "display_name");
    h.percent = jsonNumber(input, "used_percentage");
    h.counts = countPorcelain(readPorcelain(h.cwd));

    __gshared char[512] line = void;
    auto n = rowOneInto(lt.tm_hour, lt.tm_min, h, line[]);

    fwrite(&line[0], 1, n, stdout);
    fputs("\n", stdout);
}
