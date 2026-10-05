module sessionmodel;

// "i want to know on a time series if Fable, or Opus or Sonnet was active"
// "and effort as well"
// The one statement that writes a session's model and effort: a row when
// either differs from the session's newest row. ug runs it with what the
// status line hands it every second; ground runs it in tests. One module
// with one enum, compiled into both, so the two binaries cannot drift.

enum RECORD_MODEL_SQL = "INSERT INTO session_model (session, model, effort, since) SELECT ?1, ?2, ?3, ?4 "
    ~ "WHERE NOT EXISTS (SELECT 1 FROM (SELECT model, effort FROM session_model WHERE session = ?1 "
    ~ "ORDER BY id DESC LIMIT 1) WHERE model = ?2 AND effort = ?3)";

// The same change, as an attestation the stream carries to the node. Run only
// when RECORD_MODEL_SQL just wrote a row, so it never has to look for a change
// itself; the id holds the second, so one frame cannot write it twice.
enum ATTEST_MODEL_SQL = "INSERT OR IGNORE INTO attestations "
    ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ("
    ~ "'ground:session-model:' || ?1 || ':' || ?4, json_array('session:' || ?1), '[\"session:model\"]', "
    ~ "json_array('session:' || ?1), '[\"ground\"]', strftime('%Y-%m-%dT%H:%M:%SZ', ?4, 'unixepoch'), "
    ~ "'ug', json_object('model', ?2, 'effort', ?3, 'since', ?4))";
