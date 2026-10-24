module ctfe_test;

import ctfe;

// The node answers in the writer's own offset, and two writers are two
// offsets. The axis is UTC to the minute, so a laptop and a runner share it.
static assert(utcMinute("2026-10-24T07:36:53.872+02:00") == "2026-10-24 05:36");
static assert(utcMinute("2026-10-24T08:52:07+02:00") == "2026-10-24 06:52");
static assert(utcMinute("2026-10-24T06:59:53Z") == "2026-10-24 06:59");
static assert(utcMinute("2026-10-24T01:10:00+02:00") == "2026-10-23 23:10");
static assert(utcMinute("2026-03-01T00:30:00+01:00") == "2026-02-28 23:30");
static assert(utcMinute("2024-03-01T00:30:00+01:00") == "2024-02-29 23:30");
static assert(utcMinute("2026-12-31T23:30:00-01:00") == "2027-01-01 00:30");
// Not a timestamp is no minute, and the row is said rather than placed.
static assert(utcMinute("yesterday") == "");

// What a row carries is seconds to the hundredth and KiB; the page says
// seconds and MiB.
static assert(centisOf(37.29) == 3729);
static assert(centisOf(28.26) == 2826);
static assert(secondsText(3729) == "37.29");
static assert(secondsText(3700) == "37.00");
static assert(secondsText(5) == "0.05");
static assert(mibOf(2371208) == 2316);
static assert(mibOf(2371032) == 2315);
static assert(mibOf(613232) == 599);

private enum AXIS = "\\begin{axis}[date coordinates in=x, xticklabel={\\day.\\month. \\hour:\\minute}, "
    ~ "xticklabel style={font=\\scriptsize}, max space between ticks=80, ymin=0, width=\\textwidth, height=60mm, "
    ~ "legend style={at={(0.5,-0.18)}, anchor=north, legend columns=-1}, ";

private enum runs = [Run("github:linux", "2026-10-24 06:52", 2826, 2371208),
                     Run("github:linux", "2026-10-24 06:55", 4197, 2371032),
                     Run("host:darwin", "2026-10-24 05:35", 3729, 613232)];

// "can you have a CTFE Chapter with one or two line graphs on ground CTFE"
// Two graphs: how long a build took, and the most memory it held. A line a
// place it was built, so a hosted runner is never read against a laptop.
// Each graph is its own paragraph, unindented, so neither runs on from the
// lead above it. A tick says the minute as well as the day, since a day holds
// many builds, and the ticks stand far enough apart that no two labels touch.
// The legend sits under the axis, where it covers no point.
static assert(seriesTex(runs).text() ==
    "\\par\\noindent\\begin{tikzpicture}\n"
    ~ AXIS ~ "ylabel={s}]\n"
    ~ "\\addplot coordinates {(2026-10-24 06:52,28.26) (2026-10-24 06:55,41.97)};\n\\addlegendentry{github:linux}\n"
    ~ "\\addplot coordinates {(2026-10-24 05:35,37.29)};\n\\addlegendentry{host:darwin}\n"
    ~ "\\end{axis}\n\\end{tikzpicture}\n"
    ~ "\n"
    ~ "\\par\\noindent\\begin{tikzpicture}\n"
    ~ AXIS ~ "ylabel={MiB}]\n"
    ~ "\\addplot coordinates {(2026-10-24 06:52,2316) (2026-10-24 06:55,2315)};\n\\addlegendentry{github:linux}\n"
    ~ "\\addplot coordinates {(2026-10-24 05:35,599)};\n\\addlegendentry{host:darwin}\n"
    ~ "\\end{axis}\n\\end{tikzpicture}\n");

// No rows, no graphs: the chapter carries nothing rather than empty axes.
static assert(seriesTex([]).text() == "");

// The rows as the node answers them: newest first, each in its writer's
// offset. The series is oldest first, in UTC.
unittest {
    auto rs = readRuns(`[`
        ~ `{"contexts":["github:linux"],"timestamp":"2026-10-24T08:55:24+02:00",`
        ~ `"attributes":{"seconds":41.97,"peak_kib":2371032}},`
        ~ `{"contexts":["host:darwin"],"timestamp":"2026-10-24T07:35:02.597+02:00",`
        ~ `"attributes":{"seconds":37.29,"peak_kib":613232.0}},`
        ~ `{"contexts":["github:linux"],"timestamp":"2026-10-24T08:52:07+02:00",`
        ~ `"attributes":{"seconds":28.26,"peak_kib":2371208}}]`);
    assert(rs.said.length == 0);
    assert(rs.count == 3);
    assert(rs.at(0) == Run("host:darwin", "2026-10-24 05:35", 3729, 613232));
    assert(rs.at(1) == Run("github:linux", "2026-10-24 06:52", 2826, 2371208));
    assert(rs.at(2) == Run("github:linux", "2026-10-24 06:55", 4197, 2371032));
}

// A row the series cannot place is said, with its id, and the rest still stand.
unittest {
    auto rs = readRuns(`[{"id":"AS-1","contexts":["github:linux"],"timestamp":"2026-10-24T08:55:24+02:00",`
        ~ `"attributes":{"peak_kib":2371032}}]`);
    assert(rs.count == 0);
    assert(rs.said == "AS-1 carries no seconds\n");
}

// An answer that is not a list of rows is said, and nothing is drawn.
unittest {
    auto rs = readRuns(`{"error":"forbidden"}`);
    assert(rs.count == 0);
    assert(rs.said == "the node's answer is not a list of rows\n");
}
