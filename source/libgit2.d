module libgit2;

// libgit2 1.9.2, the one flake.lock's nixpkgs pins, called in this process.
// Every declaration is read off its headers; the layouts below were measured
// against them with cc and offsetof.

extern (C) {
    struct git_repository;
    struct git_commit;
    struct git_tree;
    struct git_tree_entry;
    struct git_object;
    struct git_index;
    struct git_diff;

    // GIT_EXPERIMENTAL_SHA256 is #undef in 1.9.2's experimental.h.
    struct git_oid { ubyte[20] id; }
    struct git_error { const(char)* message; int klass; }
    struct git_strarray { char** strings; size_t count; }

    struct git_diff_file {
        git_oid id;
        const(char)* path;
        ulong size;
        uint flags;
        ushort mode;
        ushort id_abbrev;
    }

    struct git_diff_delta {
        int status;
        uint flags;
        ushort similarity;
        ushort nfiles;
        git_diff_file old_file;
        git_diff_file new_file;
    }

    struct git_diff_options {
        uint version_;
        uint flags;
        int ignore_submodules;
        git_strarray pathspec;
        void* notify_cb;
        void* progress_cb;
        void* payload;
        uint context_lines;
        uint interhunk_lines;
        int oid_type;
        ushort id_abbrev;
        long max_size;
        const(char)* old_prefix;
        const(char)* new_prefix;
    }

    int git_libgit2_init();
    const(git_error)* git_error_last();

    int git_repository_open_ext(git_repository** out_, const(char)* path, uint flags,
                                const(char)* ceiling_dirs);
    void git_repository_free(git_repository* repo);
    const(char)* git_repository_workdir(const(git_repository)* repo);
    int git_repository_index(git_index** out_, git_repository* repo);
    void git_index_free(git_index* index);

    int git_revparse_single(git_object** out_, git_repository* repo, const(char)* spec);
    void git_object_free(git_object* object);
    int git_reference_name_to_id(git_oid* out_, git_repository* repo, const(char)* name);

    int git_commit_lookup(git_commit** commit, git_repository* repo, const(git_oid)* id);
    void git_commit_free(git_commit* commit);
    int git_commit_tree(git_tree** tree_out, const(git_commit)* commit);
    uint git_commit_parentcount(const(git_commit)* commit);
    int git_commit_parent(git_commit** out_, const(git_commit)* commit, uint n);
    long git_commit_time(const(git_commit)* commit);

    void git_tree_free(git_tree* tree);
    int git_tree_entry_bypath(git_tree_entry** out_, const(git_tree)* root, const(char)* path);
    void git_tree_entry_free(git_tree_entry* entry);
    const(git_oid)* git_tree_entry_id(const(git_tree_entry)* entry);
    int git_tree_entry_filemode(const(git_tree_entry)* entry);
    int git_oid_equal(const(git_oid)* a, const(git_oid)* b);

    int git_diff_options_init(git_diff_options* opts, uint version_);
    int git_diff_tree_to_index(git_diff** diff, git_repository* repo, git_tree* old_tree,
                               git_index* index, const(git_diff_options)* opts);
    int git_diff_find_similar(git_diff* diff, const(void)* options);
    size_t git_diff_num_deltas(const(git_diff)* diff);
    const(git_diff_delta)* git_diff_get_delta(const(git_diff)* diff, size_t idx);
    void git_diff_free(git_diff* diff);

    struct git_odb;
    struct git_config;
    // Only the path is read; the 64 bytes before it are times, ids and modes.
    struct git_index_entry {
        ubyte[64] head;
        const(char)* path;
    }
    size_t git_index_entrycount(const(git_index)* index);
    const(git_index_entry)* git_index_get_byindex(git_index* index, size_t n);
    int git_index_entry_stage(const(git_index_entry)* entry);
    int git_index_add_all(git_index* index, const(git_strarray)* pathspec, uint flags,
                          void* callback, void* payload);
    int git_index_update_all(git_index* index, const(git_strarray)* pathspec,
                             void* callback, void* payload);

    struct git_describe_result;
    struct git_describe_options {
        uint version_;
        uint max_candidates_tags;
        uint describe_strategy;
        const(char)* pattern;
        int only_follow_first_parent;
        int show_commit_oid_as_fallback;
    }
    struct git_describe_format_options {
        uint version_;
        uint abbreviated_size;
        int always_use_long_format;
        const(char)* dirty_suffix;
    }
    int git_describe_options_init(git_describe_options* opts, uint version_);
    int git_describe_format_options_init(git_describe_format_options* opts, uint version_);
    int git_describe_commit(git_describe_result** result, git_object* committish, git_describe_options* opts);
    int git_describe_format(git_buf* out_, const(git_describe_result)* result, const(git_describe_format_options)* opts);
    void git_describe_result_free(git_describe_result* result);

    int git_ignore_path_is_ignored(int* ignored, git_repository* repo, const(char)* path);
    const(git_index_entry)* git_index_get_bypath(git_index* index, const(char)* path, int stage);
    const(char)* git_repository_commondir(const(git_repository)* repo);
    int git_oid_fmt(char* out_, const(git_oid)* id);
    int git_oid_fromstrn(git_oid* out_, const(char)* str, size_t length);
    int git_repository_odb(git_odb** out_, git_repository* repo);
    int git_odb_exists_prefix(git_oid* out_, git_odb* db, const(git_oid)* short_id, size_t len);
    void git_odb_free(git_odb* db);
    int git_repository_config_snapshot(git_config** out_, git_repository* repo);
    int git_config_get_string(const(char)** out_, const(git_config)* cfg, const(char)* name);
    void git_config_free(git_config* cfg);

    struct git_revwalk;
    int git_revwalk_new(git_revwalk** out_, git_repository* repo);
    int git_revwalk_sorting(git_revwalk* walk, uint sort_mode);
    int git_revwalk_push_head(git_revwalk* walk);
    int git_revwalk_next(git_oid* out_, git_revwalk* walk);
    void git_revwalk_free(git_revwalk* walk);
    int git_diff_tree_to_tree(git_diff** diff, git_repository* repo, git_tree* old_tree,
                              git_tree* new_tree, const(git_diff_options)* opts);

    struct git_buf { char* ptr; size_t reserved; size_t size; }
    struct git_diff_stats;
    int git_diff_to_buf(git_buf* out_, git_diff* diff, uint format);
    int git_diff_get_stats(git_diff_stats** out_, git_diff* diff);
    int git_diff_stats_to_buf(git_buf* out_, const(git_diff_stats)* stats, uint format, size_t width);
    void git_diff_stats_free(git_diff_stats* stats);
    struct git_diff_similarity_metric {
        int function(void** out_, const(git_diff_file)* file, const(char)* fullpath, void* payload) file_signature;
        int function(void** out_, const(git_diff_file)* file, const(char)* buf, size_t buflen, void* payload) buffer_signature;
        void function(void* sig, void* payload) free_signature;
        int function(int* score, void* siga, void* sigb, void* payload) similarity;
        void* payload;
    }
    struct git_diff_find_options {
        uint version_;
        uint flags;
        ushort rename_threshold;
        ushort rename_from_rewrite_threshold;
        ushort copy_threshold;
        ushort break_rewrite_threshold;
        size_t rename_limit;
        git_diff_similarity_metric* metric;
    }
    int git_diff_find_options_init(git_diff_find_options* opts, uint version_);
    int git_diff_index_to_workdir(git_diff** diff, git_repository* repo, git_index* index,
                                  const(git_diff_options)* opts);

    struct git_patch;
    int git_patch_from_diff(git_patch** out_, git_diff* diff, size_t idx);
    int git_patch_to_buf(git_buf* out_, git_patch* patch);
    void git_patch_free(git_patch* patch);
    size_t git_diff_stats_files_changed(const(git_diff_stats)* stats);
    size_t git_diff_stats_insertions(const(git_diff_stats)* stats);
    size_t git_diff_stats_deletions(const(git_diff_stats)* stats);
    void git_buf_dispose(git_buf* buffer);
    const(char)* git_commit_summary(git_commit* commit);

    struct git_reference;
    struct git_worktree;
    struct git_signature;
    struct git_treebuilder;

    struct git_worktree_add_options {
        uint version_;
        int lock;
        int checkout_existing;
        git_reference* ref_;
        ubyte[144] checkout_options;
    }
    struct git_worktree_prune_options {
        uint version_;
        uint flags;
    }

    int git_worktree_add_options_init(git_worktree_add_options* opts, uint version_);
    int git_worktree_add(git_worktree** out_, git_repository* repo, const(char)* name,
                         const(char)* path, const(git_worktree_add_options)* opts);
    void git_worktree_free(git_worktree* wt);
    int git_worktree_open_from_repository(git_worktree** out_, git_repository* repo);
    int git_worktree_prune_options_init(git_worktree_prune_options* opts, uint version_);
    int git_worktree_prune(git_worktree* wt, git_worktree_prune_options* opts);

    int git_treebuilder_new(git_treebuilder** out_, git_repository* repo, const(git_tree)* source);
    int git_treebuilder_write(git_oid* id, git_treebuilder* bld);
    void git_treebuilder_free(git_treebuilder* bld);
    int git_tree_lookup(git_tree** out_, git_repository* repo, const(git_oid)* id);
    int git_signature_default_from_env(git_signature** author_out, git_signature** committer_out,
                                       git_repository* repo);
    void git_signature_free(git_signature* sig);
    int git_commit_create(git_oid* id, git_repository* repo, const(char)* update_ref,
                          const(git_signature)* author, const(git_signature)* committer,
                          const(char)* message_encoding, const(char)* message,
                          const(git_tree)* tree, size_t parent_count, const(git_commit)** parents);
    int git_branch_create(git_reference** out_, git_repository* repo, const(char)* branch_name,
                          const(git_commit)* target, int force);
    int git_reference_lookup(git_reference** out_, git_repository* repo, const(char)* name);
    void git_reference_free(git_reference* ref_);

    struct git_remote;
    struct git_credential;
    struct git_annotated_commit;
    struct git_status_list;

    alias git_credential_acquire_cb = int function(git_credential** out_, const(char)* url,
        const(char)* username_from_url, uint allowed_types, void* payload);

    struct git_remote_callbacks {
        uint version_;
        void* sideband_progress;
        void* completion;
        git_credential_acquire_cb credentials;
        void* certificate_check;
        void*[8] progress_and_more;
        void* payload;
        void*[2] tail;
    }
    struct git_fetch_options {
        uint version_;
        git_remote_callbacks callbacks;
        ubyte[80] rest;
    }
    struct git_status_options {
        uint version_;
        int show;
        uint flags;
        git_strarray pathspec;
        git_tree* baseline;
        ushort rename_threshold;
    }
    struct git_status_entry {
        uint status;
        git_diff_delta* head_to_index;
        git_diff_delta* index_to_workdir;
    }

    int git_stash_save(git_oid* out_, git_repository* repo, const(git_signature)* stasher,
                       const(char)* message, uint flags);
    int git_stash_apply(git_repository* repo, size_t index, const(void)* options);
    int git_stash_drop(git_repository* repo, size_t index);
    int git_index_read(git_index* index, int force);
    int git_remote_lookup(git_remote** out_, git_repository* repo, const(char)* name);
    const(char)* git_remote_url(const(git_remote)* remote);
    int git_remote_fetch(git_remote* remote, const(git_strarray)* refspecs,
                         const(git_fetch_options)* opts, const(char)* reflog_message);
    void git_remote_free(git_remote* remote);
    int git_fetch_options_init(git_fetch_options* opts, uint version_);
    int git_credential_ssh_key_from_agent(git_credential** out_, const(char)* username);
    int git_credential_ssh_key_new(git_credential** out_, const(char)* username,
                                   const(char)* publickey, const(char)* privatekey,
                                   const(char)* passphrase);
    int git_annotated_commit_lookup(git_annotated_commit** out_, git_repository* repo, const(git_oid)* id);
    void git_annotated_commit_free(git_annotated_commit* commit);
    int git_merge_analysis(uint* analysis_out, uint* preference_out, git_repository* repo,
                           const(git_annotated_commit)** their_heads, size_t their_heads_len);
    int git_merge(git_repository* repo, const(git_annotated_commit)** their_heads,
                  size_t their_heads_len, const(void)* merge_opts, const(void)* checkout_opts);
    int git_checkout_tree(git_repository* repo, const(git_object)* treeish, const(void)* opts);
    int git_repository_head(git_reference** out_, git_repository* repo);
    const(char)* git_reference_name(const(git_reference)* ref_);
    int git_reference_set_target(git_reference** out_, git_reference* ref_, const(git_oid)* id,
                                 const(char)* log_message);
    int git_index_has_conflicts(const(git_index)* index);
    int git_index_write_tree(git_oid* out_, git_index* index);
    int git_repository_state_cleanup(git_repository* repo);
    int git_reset(git_repository* repo, const(git_object)* target, int reset_type, const(void)* checkout_opts);
    int git_object_lookup(git_object** object, git_repository* repo, const(git_oid)* id, int type);
    int git_status_options_init(git_status_options* opts, uint version_);
    int git_status_list_new(git_status_list** out_, git_repository* repo, const(git_status_options)* opts);
    size_t git_status_list_entrycount(git_status_list* statuslist);
    const(git_status_entry)* git_status_byindex(git_status_list* statuslist, size_t idx);
    void git_status_list_free(git_status_list* statuslist);

    int fnmatch(const(char)* pattern, const(char)* string_, int flags);
    const(git_oid)* git_object_id(const(git_object)* obj);
    int git_revwalk_push(git_revwalk* walk, const(git_oid)* id);
    int git_revwalk_hide(git_revwalk* walk, const(git_oid)* commit_id);

    char* realpath(const(char)* path, char* resolved);
}

static assert(git_remote_callbacks.sizeof == 128 && git_remote_callbacks.credentials.offsetof == 24
              && git_remote_callbacks.certificate_check.offsetof == 32
              && git_remote_callbacks.payload.offsetof == 104);
static assert(git_fetch_options.sizeof == 216 && git_fetch_options.callbacks.offsetof == 8);
static assert(git_status_options.sizeof == 48 && git_status_options.flags.offsetof == 8
              && git_status_options.pathspec.offsetof == 16);
static assert(git_status_entry.sizeof == 24 && git_status_entry.head_to_index.offsetof == 8
              && git_status_entry.index_to_workdir.offsetof == 16);

enum GIT_STASH_INCLUDE_UNTRACKED = 1u << 1;
enum GIT_MERGE_ANALYSIS_NORMAL = 1u << 0;
enum GIT_MERGE_ANALYSIS_UP_TO_DATE = 1u << 1;
enum GIT_MERGE_ANALYSIS_FASTFORWARD = 1u << 2;
enum GIT_MERGE_ANALYSIS_UNBORN = 1u << 3;
enum GIT_MERGE_PREFERENCE_NO_FASTFORWARD = 1u << 0;
enum GIT_MERGE_PREFERENCE_FASTFORWARD_ONLY = 1u << 1;
enum GIT_RESET_HARD = 3;
enum GIT_OBJECT_ANY = -2;
enum GIT_STATUS_OPT_INCLUDE_UNTRACKED = 1u << 0;
enum GIT_STATUS_OPT_INCLUDE_IGNORED = 1u << 1;
enum GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX = 1u << 7;
enum GIT_STATUS_SHOW_WORKDIR_ONLY = 2;
enum GIT_STATUS_WT_NEW = 1u << 7;
enum GIT_STATUS_IGNORED = 1u << 14;
enum GIT_STATUS_CONFLICTED = 1u << 15;
enum GIT_CREDENTIAL_SSH_KEY = 1u << 1;
enum GIT_FETCH_OPTIONS_VERSION = 1;
enum GIT_STATUS_OPTIONS_VERSION = 1;
enum GIT_PASSTHROUGH = -30;

static assert(git_worktree_add_options.sizeof == 168 && git_worktree_add_options.ref_.offsetof == 16
              && git_worktree_add_options.checkout_options.offsetof == 24);
static assert(git_worktree_prune_options.sizeof == 8 && git_worktree_prune_options.flags.offsetof == 4);

enum GIT_WORKTREE_ADD_OPTIONS_VERSION = 1;
enum GIT_WORKTREE_PRUNE_OPTIONS_VERSION = 1;
enum GIT_WORKTREE_PRUNE_VALID = 1u << 0;
enum GIT_WORKTREE_PRUNE_WORKING_TREE = 1u << 2;

enum GIT_SORT_TIME = 1u << 1;
enum GIT_DIFF_FORMAT_PATCH = 1u;
enum GIT_DIFF_STATS_SHORT = 1u << 1;
enum GIT_DIFF_INDENT_HEURISTIC = 1u << 18;

// What of a diff is printed.
enum Shown { patch, shortStat, names }

enum GIT_EAMBIGUOUS = -5;

static assert(git_index_entry.sizeof == 72 && git_index_entry.path.offsetof == 64);
static assert(git_describe_options.sizeof == 32 && git_describe_options.describe_strategy.offsetof == 8
              && git_describe_options.pattern.offsetof == 16
              && git_describe_options.show_commit_oid_as_fallback.offsetof == 28);
static assert(git_describe_format_options.sizeof == 24
              && git_describe_format_options.abbreviated_size.offsetof == 4
              && git_describe_format_options.dirty_suffix.offsetof == 16);
enum GIT_DESCRIBE_TAGS = 1;
enum GIT_INDEX_ADD_DEFAULT = 0u;

static assert(git_oid.sizeof == 20);
static assert(git_error.sizeof == 16);
static assert(git_strarray.sizeof == 16);
static assert(git_diff_file.sizeof == 48 && git_diff_file.path.offsetof == 24
              && git_diff_file.size.offsetof == 32 && git_diff_file.flags.offsetof == 40
              && git_diff_file.mode.offsetof == 44);
static assert(git_diff_delta.sizeof == 112 && git_diff_delta.old_file.offsetof == 16
              && git_diff_delta.new_file.offsetof == 64);
static assert(git_diff_options.sizeof == 96 && git_diff_options.flags.offsetof == 4
              && git_diff_options.pathspec.offsetof == 16
              && git_diff_options.context_lines.offsetof == 56
              && git_diff_options.id_abbrev.offsetof == 68
              && git_diff_options.max_size.offsetof == 72
              && git_diff_options.new_prefix.offsetof == 88);

enum GIT_ENOTFOUND = -3;
enum GIT_EUNBORNBRANCH = -9;
enum GIT_DELTA_DELETED = 2;
enum GIT_DIFF_INCLUDE_TYPECHANGE = 1u << 6;
enum GIT_DIFF_INCLUDE_UNTRACKED = 1u << 3;
enum GIT_DIFF_OPTIONS_VERSION = 1;

private __gshared bool inited;

static assert(git_diff_find_options.sizeof == 32 && git_diff_find_options.rename_threshold.offsetof == 8
              && git_diff_find_options.rename_limit.offsetof == 16 && git_diff_find_options.metric.offsetof == 24);
static assert(git_diff_similarity_metric.sizeof == 40 && git_diff_similarity_metric.similarity.offsetof == 24
              && git_diff_similarity_metric.payload.offsetof == 32);

// A rename scored the way git scores it (diffcore-delta.c, estimate_similarity).
// libgit2's own metric called an edited rename 88% that git calls 76%.
private struct Span { uint hash; uint bytes; }
private struct SpanSig { bool regular; size_t size; size_t count; Span* spans; }

enum GIT_MAX_SCORE = 60000;
enum GIT_MINIMUM_SCORE = 30000;

extern (C) private int spanOrder(const(void)* a, const(void)* b) {
    auto x = (cast(const(Span)*) a).hash, y = (cast(const(Span)*) b).hash;
    return x < y ? -1 : x > y ? 1 : 0;
}

// Chunks that end at a newline or after 64 bytes, each hashed, with the bytes
// per hash summed; a CR before a LF is skipped in text.
private SpanSig* spanSig(const(ubyte)* buf, size_t len, ushort mode) {
    import core.stdc.stdlib : malloc, qsort;
    auto sig = cast(SpanSig*) malloc(SpanSig.sizeof);
    if (sig is null) return null;
    *sig = SpanSig.init;
    sig.size = len;
    // Only regular files are scored; a symlink is a rename only when exact.
    sig.regular = (mode & 0xF000) == 0x8000;
    if (!sig.regular || len == 0) return sig;
    sig.spans = cast(Span*) malloc(Span.sizeof * (len + 1));
    if (sig.spans is null) return sig;

    // A NUL in the first 8000 bytes is binary, as buffer_is_binary reads it.
    bool text = true;
    foreach (i; 0 .. len < 8000 ? len : 8000) if (buf[i] == 0) { text = false; break; }

    enum HASHBASE = 107_927;
    uint accum1, accum2, n;
    size_t count;
    for (size_t i = 0; i < len; i++) {
        uint c = buf[i];
        uint old1 = accum1;
        if (text && c == '\r' && i + 1 < len && buf[i + 1] == '\n') continue;
        accum1 = (accum1 << 7) ^ (accum2 >> 25);
        accum2 = (accum2 << 7) ^ (old1 >> 25);
        accum1 += c;
        if (++n < 64 && c != '\n') continue;
        sig.spans[count++] = Span((accum1 + accum2 * 0x61) % HASHBASE, n);
        n = 0;
        accum1 = accum2 = 0;
    }
    if (n > 0) sig.spans[count++] = Span((accum1 + accum2 * 0x61) % HASHBASE, n);

    qsort(sig.spans, count, Span.sizeof, &spanOrder);
    size_t merged;
    foreach (i; 0 .. count) {
        if (merged > 0 && sig.spans[merged - 1].hash == sig.spans[i].hash) sig.spans[merged - 1].bytes += sig.spans[i].bytes;
        else sig.spans[merged++] = sig.spans[i];
    }
    sig.count = merged;
    return sig;
}

extern (C) private int sigOfBuffer(void** out_, const(git_diff_file)* file, const(char)* buf, size_t len, void*) {
    *out_ = spanSig(cast(const(ubyte)*) buf, len, file.mode);
    return *out_ is null ? -1 : 0;
}

extern (C) private int sigOfFile(void** out_, const(git_diff_file)* file, const(char)* path, void*) {
    import core.stdc.stdio : fopen, fread, fclose, fseek, ftell, SEEK_END, SEEK_SET;
    import core.stdc.stdlib : malloc, free;
    auto f = fopen(path, "rb");
    if (f is null) return -1;
    scope (exit) fclose(f);
    fseek(f, 0, SEEK_END);
    auto size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 0) return -1;
    auto buf = cast(ubyte*) malloc(size > 0 ? size : 1);
    if (buf is null) return -1;
    scope (exit) free(buf);
    auto got = fread(buf, 1, size, f);
    *out_ = spanSig(buf, got, file.mode);
    return *out_ is null ? -1 : 0;
}

extern (C) private void sigFree(void* sig, void*) {
    import core.stdc.stdlib : free;
    auto s = cast(SpanSig*) sig;
    if (s is null) return;
    if (s.spans !is null) free(s.spans);
    free(s);
}

// The 0-100 that `similarity index` prints: git's score over its maximum.
extern (C) private int sigScore(int* score, void* a, void* b, void*) {
    *score = gitScore(cast(SpanSig*) a, cast(SpanSig*) b) * 100 / GIT_MAX_SCORE;
    return 0;
}

// The bytes the two share over the larger size. Sizes apart by more than half
// are not considered.
private int gitScore(const(SpanSig)* a, const(SpanSig)* b) {
    if (!a.regular || !b.regular || a.size == 0 || b.size == 0) return 0;
    auto maxSize = a.size > b.size ? a.size : b.size;
    auto baseSize = a.size < b.size ? a.size : b.size;
    if (cast(ulong) maxSize * (GIT_MAX_SCORE - GIT_MINIMUM_SCORE) < cast(ulong) (maxSize - baseSize) * GIT_MAX_SCORE)
        return 0;
    ulong copied;
    size_t i, j;
    while (i < a.count && j < b.count) {
        if (a.spans[i].hash < b.spans[j].hash) i++;
        else if (a.spans[i].hash > b.spans[j].hash) j++;
        else {
            copied += a.spans[i].bytes < b.spans[j].bytes ? a.spans[i].bytes : b.spans[j].bytes;
            i++;
            j++;
        }
    }
    return cast(int) (copied * GIT_MAX_SCORE / maxSize);
}

private __gshared git_diff_similarity_metric gitMetric = git_diff_similarity_metric(
    &sigOfFile, &sigOfBuffer, &sigFree, &sigScore, null);

// Renames found as diff.renames asks, scored with git's metric.
private int findRenames(git_diff* diff) {
    git_diff_find_options opts;
    if (git_diff_find_options_init(&opts, 1) < 0) return -1;
    opts.metric = &gitMetric;
    return git_diff_find_similar(diff, &opts);
}

// One `git add`: where it stood, relative to the top of the tree, and what it
// named from there. `update` is -u, tracked files only.
struct Adding {
    const(char)[] base;
    const(char)[][] specs;
    bool update;
}

// A path an add named, from where it stood, as one from the top of the tree:
// `.` and `..` walked, NUL-terminated in `into`. 0 is the whole tree.
size_t joinSpec(const(char)[] base, const(char)[] spec, char[] into) {
    char[1024] joined = 0;
    size_t jn;
    void put(const(char)[] s) { foreach (c; s) if (jn < joined.length) joined[jn++] = c; }
    if (spec.length == 0 || spec[0] != '/') { put(base); put("/"); }
    put(spec);

    size_t n;
    size_t i;
    while (i < jn) {
        size_t e = i;
        while (e < jn && joined[e] != '/') e++;
        auto seg = joined[i .. e];
        i = e + 1;
        if (seg.length == 0 || seg == ".") continue;
        if (seg == "..") {
            while (n > 0 && into[n - 1] != '/') n--;
            if (n > 0) n--;
            continue;
        }
        if (n > 0) into[n++] = '/';
        foreach (c; seg) if (n < into.length - 1) into[n++] = c;
    }
    into[n] = 0;
    return n;
}

unittest {
    char[64] b;
    assert(joinSpec("", "a.d", b[]) == 3 && b[0 .. 3] == "a.d");
    assert(joinSpec("sub", "x.d", b[]) == 7 && b[0 .. 7] == "sub/x.d");
    assert(joinSpec("sub", ".", b[]) == 3 && b[0 .. 3] == "sub");
    assert(joinSpec("", ".", b[]) == 0, "the whole tree");
    assert(joinSpec("sub/deep", "../x.d", b[]) == 7 && b[0 .. 7] == "sub/x.d");
}

// Bytewise by path, as git orders its index, then by stage.
extern (C) private int entryOrder(const(void)* a, const(void)* b) {
    import core.stdc.string : strcmp;
    auto x = *cast(const(git_index_entry)**) a;
    auto y = *cast(const(git_index_entry)**) b;
    auto c = strcmp(x.path, y.path);
    if (c != 0) return c;
    return git_index_entry_stage(x) - git_index_entry_stage(y);
}

// A deletion by its old name, everything else by its new one.
private const(char)* pathOf(const(git_diff_delta)* d) {
    return d.status == GIT_DELTA_DELETED ? d.old_file.path : d.new_file.path;
}

private bool sameText(const(char)* a, const(char)* b) {
    if (a is null || b is null) return false;
    size_t i;
    for (; a[i] != 0 && b[i] != 0; i++) if (a[i] != b[i]) return false;
    return a[i] == b[i];
}

// Byte by byte: a slice assignment is a druntime call, and ug links none.
private void copy(T)(T[] into, const(T)[] from) {
    foreach (i, c; from) into[i] = c;
}

private __gshared char[1024] fetchedBuf = 0;

// The url as fetch writes it into FETCH_HEAD: transport_anonymize_url's user
// dropped, then trailing slashes and a last `.git` cut, as builtin/fetch.c cuts.
const(char)[] fetchedUrl(const(char)[] url) {
    const(char)[] anon = url;
    size_t at = url.length;
    foreach (i, c; url) if (c == '@') { at = i; break; }
    size_t colon = url.length, slash = url.length;
    foreach (i, c; url) if (c == ':') { colon = i; break; }
    foreach (i, c; url) if (c == '/') { slash = i; break; }
    bool local = colon == url.length || (slash < url.length && slash < colon);
    if (!local && at < url.length) {
        auto part = url[at + 1 .. $];
        size_t scheme = url.length;
        foreach (i; 0 .. url.length) if (i + 3 <= url.length && url[i .. i + 3] == "://") { scheme = i; break; }
        if (scheme == url.length) {
            foreach (c; part) if (c == ':') { anon = part; break; }
        } else {
            bool fine = true;
            foreach (c; url[0 .. scheme])
                if (!(c == '+' || c == '.' || c == '-' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')))
                    fine = false;
            size_t firstSlash = url.length;
            foreach (i; scheme + 3 .. url.length) if (url[i] == '/') { firstSlash = i; break; }
            if (fine && !(firstSlash < at)) {
                size_t n;
                foreach (c; url[0 .. scheme + 3]) fetchedBuf[n++] = c;
                foreach (c; part) if (n < fetchedBuf.length) fetchedBuf[n++] = c;
                anon = fetchedBuf[0 .. n];
            }
        }
    }
    long i = cast(long) anon.length - 1;
    while (i >= 0 && anon[cast(size_t) i] == '/') i--;
    size_t len = cast(size_t) (i + 1);
    if (4 < i && anon[cast(size_t) i - 3 .. cast(size_t) i + 1] == ".git") len = cast(size_t) i - 3;
    return anon[0 .. len];
}

unittest {
    assert(fetchedUrl("git@github.com:teranos/QNTX.git") == "github.com:teranos/QNTX");
    assert(fetchedUrl("https://user@github.com/teranos/QNTX.git/") == "https://github.com/teranos/QNTX");
    assert(fetchedUrl("/tmp/x/origin.git") == "/tmp/x/origin");
    assert(fetchedUrl("https://github.com/teranos/QNTX") == "https://github.com/teranos/QNTX");
}

// The host a remote url reaches: `user@host:path` or `scheme://user@host:port/path`.
const(char)[] hostOf(const(char)[] url) {
    size_t start;
    bool scheme;
    foreach (i; 0 .. url.length) {
        if (i + 2 < url.length && url[i] == ':' && url[i + 1] == '/' && url[i + 2] == '/') {
            start = i + 3;
            scheme = true;
            break;
        }
    }
    auto rest = url[start .. $];
    size_t end = rest.length;
    foreach (i, c; rest) if (c == '/') { end = i; break; }
    rest = rest[0 .. end];
    foreach (i, c; rest) if (c == '@') { rest = rest[i + 1 .. $]; break; }
    foreach (i, c; rest) if (c == ':') { rest = rest[0 .. i]; break; }
    if (!scheme && end == url.length - start && rest.length == url.length) return null;
    return rest;
}

private bool globMatch(const(char)[] pattern, const(char)[] text) {
    if (pattern.length == 0) return text.length == 0;
    if (pattern[0] == '*') {
        foreach (i; 0 .. text.length + 1) if (globMatch(pattern[1 .. $], text[i .. $])) return true;
        return false;
    }
    if (text.length == 0) return false;
    if (pattern[0] == '?' || lower(pattern[0]) == lower(text[0])) return globMatch(pattern[1 .. $], text[1 .. $]);
    return false;
}

private char lower(char c) { return c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c; }

private bool keyword(const(char)[] word, const(char)[] want) {
    if (word.length != want.length) return false;
    foreach (i, c; word) if (lower(c) != lower(want[i])) return false;
    return true;
}

// The keys ssh would offer `host`: every IdentityFile a matching Host block of
// `config` names, in order, `~` as `home`; ssh's own defaults when none do.
size_t identityFiles(const(char)[] config, const(char)[] host, const(char)[] home, char[][] into) {
    size_t count;
    bool applies = true;
    void add(const(char)[] path) {
        if (count >= into.length) return;
        size_t n;
        if (path.length > 0 && path[0] == '~') {
            foreach (c; home) if (n < into[count].length - 1) into[count][n++] = c;
            path = path[1 .. $];
        }
        foreach (c; path) if (n < into[count].length - 1) into[count][n++] = c;
        into[count][n] = 0;
        into[count] = into[count][0 .. n];
        count++;
    }

    size_t i;
    while (i < config.length) {
        size_t e = i;
        while (e < config.length && config[e] != '\n') e++;
        auto line = config[i .. e];
        i = e + 1;
        size_t a;
        while (a < line.length && (line[a] == ' ' || line[a] == '\t')) a++;
        line = line[a .. $];
        while (line.length > 0 && (line[$ - 1] == '\r' || line[$ - 1] == ' ' || line[$ - 1] == '\t')) line = line[0 .. $ - 1];
        if (line.length == 0 || line[0] == '#') continue;
        size_t k;
        while (k < line.length && line[k] != ' ' && line[k] != '\t' && line[k] != '=') k++;
        auto word = line[0 .. k];
        auto value = line[k .. $];
        while (value.length > 0 && (value[0] == ' ' || value[0] == '\t' || value[0] == '=')) value = value[1 .. $];

        if (keyword(word, "Host")) {
            bool yes, no;
            size_t p;
            while (p < value.length) {
                while (p < value.length && (value[p] == ' ' || value[p] == '\t')) p++;
                size_t q = p;
                while (q < value.length && value[q] != ' ' && value[q] != '\t') q++;
                auto pat = value[p .. q];
                p = q;
                if (pat.length == 0) continue;
                if (pat[0] == '!') { if (globMatch(pat[1 .. $], host)) no = true; }
                else if (globMatch(pat, host)) yes = true;
            }
            applies = yes && !no;
            continue;
        }
        // A Match block's conditions are not read here, so it is not assumed to apply.
        if (keyword(word, "Match")) { applies = false; continue; }
        if (applies && keyword(word, "IdentityFile")) {
            if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"') value = value[1 .. $ - 1];
            add(value);
        }
    }
    if (count > 0) return count;
    static immutable string[5] defaults = ["~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ecdsa_sk",
                                           "~/.ssh/id_ed25519", "~/.ssh/id_ed25519_sk"];
    foreach (d; defaults) add(d);
    return count;
}

unittest {
    enum cfg = "Host github.com\n    HostName github.com\n    IdentityFile ~/.ssh/gh\n    User git\n\n"
             ~ "Host *\n  ControlMaster auto\n";
    char[256][4] bufs;
    char[][4] into;
    foreach (i; 0 .. 4) into[i] = bufs[i][];
    assert(identityFiles(cfg, "github.com", "/home/u", into[]) == 1);
    assert(into[0] == "/home/u/.ssh/gh");

    foreach (i; 0 .. 4) into[i] = bufs[i][];
    assert(identityFiles(cfg, "gitlab.com", "/home/u", into[]) == 4, "no IdentityFile: ssh's defaults");
    assert(into[0] == "/home/u/.ssh/id_rsa");

    assert(hostOf("git@github.com:teranos/QNTX.git") == "github.com");
    assert(hostOf("ssh://git@github.com:22/teranos/QNTX.git") == "github.com");
    assert(hostOf("https://github.com/teranos/QNTX") == "github.com");
}

// Who a credential is asked for, and how far down the list of keys the asking is.
private struct Asking {
    int tried;
    char[256][8] bufs = 0;
    char[][8] keys;
    size_t count;
    char[260] pub = 0;
}

// The agent first, then each key ssh would offer, as libgit2 asks again after
// every refusal. Nothing left is a refusal libgit2 reports.
extern (C) private int askCredential(git_credential** out_, const(char)* url, const(char)* user,
                                     uint allowed, void* payload) {
    auto a = cast(Asking*) payload;
    if (!(allowed & GIT_CREDENTIAL_SSH_KEY)) return GIT_PASSTHROUGH;
    auto who = user is null ? "git" : user;
    import core.stdc.stdlib : getenv;
    import core.sys.posix.unistd : access, F_OK;
    for (;;) {
        auto at = a.tried++;
        if (at == 0) {
            if (getenv("SSH_AUTH_SOCK") is null) continue;
            if (git_credential_ssh_key_from_agent(out_, who) == 0) return 0;
            continue;
        }
        auto k = at - 1;
        if (k >= a.count) return GIT_PASSTHROUGH;
        auto key = a.keys[k];
        if (access(key.ptr, F_OK) != 0) continue;
        copy(a.pub[0 .. key.length], key);
        copy(a.pub[key.length .. key.length + 4], ".pub");
        a.pub[key.length + 4] = 0;
        auto pub = access(&a.pub[0], F_OK) == 0 ? &a.pub[0] : null;
        if (git_credential_ssh_key_new(out_, who, pub, key.ptr, null) == 0) return 0;
    }
}

// `rm -rf`, without following a symlink out of the tree.
private bool removeAll(const(char)* path) {
    import core.sys.posix.sys.stat : lstat, stat_t, S_IFMT, S_IFDIR;
    import core.sys.posix.unistd : unlink, rmdir;
    import core.sys.posix.dirent : opendir, readdir, closedir;
    stat_t st;
    if (lstat(path, &st) != 0) return true;
    if ((st.st_mode & S_IFMT) != S_IFDIR) return unlink(path) == 0;
    auto dir = opendir(path);
    if (dir is null) return false;
    bool ok = true;
    char[4096] child = 0;
    size_t base;
    while (path[base] != 0 && base < child.length - 2) { child[base] = path[base]; base++; }
    if (base > 0 && child[base - 1] != '/') child[base++] = '/';
    for (auto e = readdir(dir); e !is null; e = readdir(dir)) {
        size_t len;
        while (e.d_name[len] != 0) len++;
        auto name = e.d_name[0 .. len];
        if (name == "." || name == "..") continue;
        if (base + len + 1 > child.length) { ok = false; continue; }
        copy(child[base .. base + len], name);
        child[base + len] = 0;
        if (!removeAll(&child[0])) ok = false;
    }
    closedir(dir);
    return rmdir(path) == 0 && ok;
}

// How many objects the packs under `commondir` hold, alternates included: the
// count git takes its abbreviation length from. Loose objects are not in it.
private ulong packedObjects(const(char)* commondir) {
    if (commondir is null) return 0;
    char[4096] objects = 0;
    size_t n;
    while (commondir[n] != 0 && n < objects.length - 16) { objects[n] = commondir[n]; n++; }
    if (n > 0 && objects[n - 1] != '/') objects[n++] = '/';
    foreach (c; "objects") objects[n++] = c;
    return packsUnder(objects[0 .. n], 0);
}

private ulong packsUnder(const(char)[] objects, int depth) {
    import core.sys.posix.dirent : opendir, readdir, closedir;
    import core.sys.posix.unistd : access, F_OK;
    import core.stdc.stdio : fopen, fread, fclose;

    char[4096] buf = 0;
    size_t bn;
    void at(const(char)[] tail) {
        bn = 0;
        foreach (c; objects) if (bn < buf.length - 1) buf[bn++] = c;
        foreach (c; tail) if (bn < buf.length - 1) buf[bn++] = c;
        buf[bn] = 0;
    }

    ulong total;
    at("/pack");
    auto dir = opendir(&buf[0]);
    if (dir !is null) {
        scope (exit) closedir(dir);
        for (auto e = readdir(dir); e !is null; e = readdir(dir)) {
            size_t len;
            while (e.d_name[len] != 0) len++;
            auto name = e.d_name[0 .. len];
            if (len <= 4 || name[$ - 4 .. $] != ".idx") continue;
            char[512] pack = 0;
            copy(pack[0 .. len - 4], name[0 .. len - 4]);
            copy(pack[len - 4 .. len + 1], ".pack");
            at("/pack/");
            auto stem = bn;
            foreach (c; pack[0 .. len + 1]) if (bn < buf.length - 1) buf[bn++] = c;
            buf[bn] = 0;
            if (access(&buf[0], F_OK) != 0) continue;
            bn = stem;
            foreach (c; name) if (bn < buf.length - 1) buf[bn++] = c;
            buf[bn] = 0;
            auto f = fopen(&buf[0], "rb");
            if (f is null) continue;
            ubyte[8 + 1024] head;
            auto got = fread(&head[0], 1, head.length, f);
            fclose(f);
            // Version 2 opens with \377tOc and a version word; version 1 is
            // the fanout table from the first byte. Its last entry is the count.
            size_t fan = (got >= 8 && head[0] == 0xFF && head[1] == 't' && head[2] == 'O' && head[3] == 'c') ? 8 : 0;
            auto last = fan + 255 * 4;
            if (got < last + 4) continue;
            total += (cast(ulong) head[last] << 24) | (head[last + 1] << 16) | (head[last + 2] << 8) | head[last + 3];
        }
    }

    // git follows alternates five deep.
    if (depth >= 5) return total;
    at("/info/alternates");
    auto alt = fopen(&buf[0], "rb");
    if (alt is null) return total;
    char[8192] list = 0;
    auto got = fread(&list[0], 1, list.length, alt);
    fclose(alt);
    size_t start;
    foreach (i; 0 .. got + 1) {
        if (i < got && list[i] != '\n') continue;
        auto line = list[start .. i];
        start = i + 1;
        while (line.length > 0 && (line[$ - 1] == '\r' || line[$ - 1] == ' ')) line = line[0 .. $ - 1];
        if (line.length == 0 || line[0] == '#') continue;
        char[4096] other = 0;
        size_t on;
        if (line[0] != '/') {
            foreach (c; objects) other[on++] = c;
            other[on++] = '/';
        }
        foreach (c; line) if (on < other.length - 1) other[on++] = c;
        total += packsUnder(other[0 .. on], depth + 1);
    }
    return total;
}

// When a file was last committed, as `git log -1 --format=%ct` says it: 0 when
// no commit names it.
struct Last {
    bool ok;
    long since;
}

// One side of a commit, at one path: what is there, or that nothing is.
private struct Side {
    bool present;
    git_oid id;
    int mode;
}

private bool same(const ref Side a, const ref Side b) {
    if (a.present != b.present) return false;
    if (!a.present) return true;
    return a.mode == b.mode && git_oid_equal(&a.id, &b.id) != 0;
}

// A repository, opened from anywhere inside it, the way `git -C` finds one.
struct Repo {
    private git_repository* repo;
    private char[1024] whyBuf = 0;
    private size_t whyLen;
    private char[4096] rootBuf = 0;
    private size_t rootLen;
    private char[4096] pathBuf = 0;

    // libgit2's code for the open, GIT_ENOTFOUND when no repository is there.
    int code;

    // The last refusal was a diff larger than the caller's buffer.
    bool overflowed;

    // What libgit2 said the last time it refused.
    const(char)[] why() const return { return whyBuf[0 .. whyLen]; }

    // A refusal ground judged itself. libgit2's last error belongs to some
    // earlier call, and appending it named a missing object for a conflict.
    private void refuse(const(char)[] what) {
        whyLen = 0;
        foreach (c; what) if (whyLen < whyBuf.length) whyBuf[whyLen++] = c;
    }

    private void say(const(char)[] what) {
        whyLen = 0;
        void put(const(char)[] s) { foreach (c; s) if (whyLen < whyBuf.length) whyBuf[whyLen++] = c; }
        put(what);
        auto e = git_error_last();
        if (e !is null && e.message !is null) {
            put(": ");
            size_t n;
            while (e.message[n] != 0) n++;
            put(e.message[0 .. n]);
        }
    }

    private const(char)* z(const(char)[] s) return {
        if (s.length >= pathBuf.length) return null;
        foreach (i, c; s) pathBuf[i] = c;
        pathBuf[s.length] = 0;
        return &pathBuf[0];
    }

    bool open(const(char)[] path) {
        if (!inited) {
            if (git_libgit2_init() < 0) { say("libgit2 would not start"); return false; }
            inited = true;
        }
        rootLen = 0;
        auto p = z(path);
        if (p is null) { refuse("the path is longer than ground holds"); return false; }
        code = git_repository_open_ext(&repo, p, 0, null);
        if (code < 0) {
            repo = null;
            say("no repository opens here");
            return false;
        }
        return true;
    }

    void close() {
        if (repo !is null) git_repository_free(repo);
        repo = null;
    }

    // The top of the working tree, as rev-parse --show-toplevel prints it:
    // symlinks resolved, no trailing slash. Empty for a bare repository.
    const(char)[] root() return {
        if (rootLen > 0) return rootBuf[0 .. rootLen];
        auto w = git_repository_workdir(repo);
        if (w is null) return null;
        if (realpath(w, &rootBuf[0]) is null) { say("the working tree's path would not resolve"); return null; }
        while (rootBuf[rootLen] != 0) rootLen++;
        while (rootLen > 1 && rootBuf[rootLen - 1] == '/') rootLen--;
        return rootBuf[0 .. rootLen];
    }

    // What `git diff --cached --name-only` prints, one name a line: the index
    // against HEAD, renames found as git finds them, a deletion by its old name.
    // Null when it could not be read whole.
    const(char)[] staged(char[] into) return {
        git_tree* head;
        git_object* obj;
        auto rc = git_revparse_single(&obj, repo, "HEAD^{tree}");
        if (rc == 0) head = cast(git_tree*) obj;
        else if (rc != GIT_ENOTFOUND && rc != GIT_EUNBORNBRANCH) { say("HEAD's tree would not read"); return null; }
        scope (exit) if (head !is null) git_object_free(cast(git_object*) head);

        git_index* index;
        if (git_repository_index(&index, repo) < 0) { say("the index would not read"); return null; }
        scope (exit) git_index_free(index);

        git_diff_options opts;
        if (!diffOptions(opts)) return null;
        git_diff* diff;
        if (git_diff_tree_to_index(&diff, repo, head, index, &opts) < 0) { say("the index would not diff"); return null; }
        scope (exit) git_diff_free(diff);
        if (findRenames(diff) < 0) { say("renames would not be found"); return null; }
        size_t n;
        if (!namesOf(diff, into, n)) return null;
        return into[0 .. n];
    }

    // The names a diff lists, one a line, appended at `n`, the renames already
    // found. A path both deleted and added, a file that became a symlink, is
    // named once, as --name-only names it. False when `into` is full.
    private bool namesOf(git_diff* diff, char[] into, ref size_t n) {
        const(char)* last;
        foreach (i; 0 .. git_diff_num_deltas(diff)) {
            auto p = pathOf(git_diff_get_delta(diff, i));
            if (sameText(p, last)) continue;
            last = p;
            size_t len;
            while (p[len] != 0) len++;
            if (n + len + 1 > into.length) { refuse("more names than ground holds"); return false; }
            if (n > 0) into[n++] = '\n';
            foreach (c; p[0 .. len]) into[n++] = c;
        }
        return true;
    }

    private bool diffOptions(ref git_diff_options opts) {
        if (git_diff_options_init(&opts, GIT_DIFF_OPTIONS_VERSION) < 0) { say("diff options would not set"); return false; }
        return true;
    }

    // What `git log -<count> --name-only --pretty=` names, blank lines left
    // out: the newest commits by date, each against its one parent, a root
    // commit against nothing, a merge naming nothing.
    const(char)[] recent(size_t count, char[] into) return {
        git_revwalk* walk;
        if (git_revwalk_new(&walk, repo) < 0) { say("the history would not walk"); return null; }
        scope (exit) git_revwalk_free(walk);
        git_revwalk_sorting(walk, GIT_SORT_TIME);
        auto rc = git_revwalk_push_head(walk);
        if (rc == GIT_ENOTFOUND || rc == GIT_EUNBORNBRANCH) return into[0 .. 0];
        if (rc < 0) { say("HEAD would not resolve"); return null; }

        git_diff_options opts;
        if (!diffOptions(opts)) return null;
        size_t n;
        git_oid id;
        foreach (k; 0 .. count) {
            if (git_revwalk_next(&id, walk) != 0) break;
            git_commit* c;
            if (git_commit_lookup(&c, repo, &id) < 0) { say("a commit would not read"); return null; }
            scope (exit) git_commit_free(c);
            auto parents = git_commit_parentcount(c);
            if (parents > 1) continue;

            git_tree* tree;
            if (git_commit_tree(&tree, c) < 0) { say("a tree would not read"); return null; }
            scope (exit) git_tree_free(tree);
            git_tree* before;
            if (parents == 1) {
                git_commit* p;
                if (git_commit_parent(&p, c, 0) < 0) { say("a parent would not read"); return null; }
                auto ok = git_commit_tree(&before, p) == 0;
                git_commit_free(p);
                if (!ok) { say("a tree would not read"); return null; }
            }
            scope (exit) if (before !is null) git_tree_free(before);

            git_diff* diff;
            if (git_diff_tree_to_tree(&diff, repo, before, tree, &opts) < 0) { say("a commit would not diff"); return null; }
            scope (exit) git_diff_free(diff);
            if (findRenames(diff) < 0) { say("renames would not be found"); return null; }
            if (!namesOf(diff, into, n)) return null;
        }
        return into[0 .. n];
    }

    // The tree a revision names, or null with the reason said.
    private git_tree* treeAt(const(char)[] rev) {
        __gshared char[512] spec = 0;
        if (rev.length + 8 > spec.length) { refuse("the revision is longer than ground holds"); return null; }
        copy(spec[0 .. rev.length], rev);
        copy(spec[rev.length .. rev.length + 7], "^{tree}");
        spec[rev.length + 7] = 0;
        git_object* obj;
        if (git_revparse_single(&obj, repo, &spec[0]) < 0) { say("the revision would not resolve"); return null; }
        return cast(git_tree*) obj;
    }

    // One tree against another, as `git diff` takes them: renames found with
    // git's metric, the indent heuristic on, ids at git's own length. A file
    // that became a symlink is a deletion and an addition here.
    private git_diff* treeDiff(git_tree* before, git_tree* after, uint context) {
        git_diff_options opts;
        if (!diffOptions(opts)) return null;
        opts.flags |= GIT_DIFF_INDENT_HEURISTIC;
        opts.context_lines = context;
        opts.id_abbrev = cast(ushort) abbrevLength();
        git_diff* diff;
        if (git_diff_tree_to_tree(&diff, repo, before, after, &opts) < 0) { say("the trees would not diff"); return null; }
        if (findRenames(diff) < 0) { git_diff_free(diff); say("renames would not be found"); return null; }
        return diff;
    }

    // One tree against another, printed the way `git diff` prints it.
    private const(char)[] printed(git_tree* before, git_tree* after, uint context, Shown what, char[] into) {
        overflowed = false;
        auto split = treeDiff(before, after, context);
        if (split is null) return null;
        scope (exit) git_diff_free(split);
        if (what == Shown.names) {
            size_t n;
            if (!namesOf(split, into, n)) return null;
            return into[0 .. n];
        }
        if (what == Shown.shortStat) return shortStat(split, into);

        // File by file, so a path that is both deleted and added prints its
        // deletion first, the order git prints them in.
        size_t n;
        auto count = git_diff_num_deltas(split);
        bool patchOf(size_t idx) {
            git_patch* p;
            if (git_patch_from_diff(&p, split, idx) < 0) { say("the patch would not print"); return false; }
            scope (exit) git_patch_free(p);
            git_buf buf;
            scope (exit) git_buf_dispose(&buf);
            if (git_patch_to_buf(&buf, p) < 0) { say("the patch would not print"); return false; }
            foreach (k; 0 .. buf.size) {
                if (n == into.length) { overflowed = true; return true; }
                into[n++] = buf.ptr[k];
            }
            return true;
        }
        for (size_t i = 0; i < count; i++) {
            auto d = git_diff_get_delta(split, i);
            if (i + 1 < count) {
                auto e = git_diff_get_delta(split, i + 1);
                if (d.status != GIT_DELTA_DELETED && e.status == GIT_DELTA_DELETED
                    && sameText(d.new_file.path, e.old_file.path)) {
                    if (!patchOf(i + 1) || !patchOf(i)) return null;
                    i++;
                    continue;
                }
            }
            if (!patchOf(i)) return null;
        }
        // A trailing newline is git's, and the caller reads git's output without it.
        while (n > 0 && into[n - 1] == '\n' && !overflowed) n--;
        return into[0 .. n];
    }

    // `--shortstat` in git's words (diff.c, print_stat_summary_inserts_deletes):
    // the files as the names count them, the lines as the patch counts them.
    private const(char)[] shortStat(git_diff* split, char[] into) {
        git_diff_stats* lines;
        if (git_diff_get_stats(&lines, split) < 0) { say("the stat would not count"); return null; }
        scope (exit) git_diff_stats_free(lines);
        size_t f;
        const(char)* last;
        foreach (i; 0 .. git_diff_num_deltas(split)) {
            auto p = pathOf(git_diff_get_delta(split, i));
            if (!sameText(p, last)) f++;
            last = p;
        }
        auto ins = git_diff_stats_insertions(lines);
        auto del = git_diff_stats_deletions(lines);

        size_t n;
        void put(const(char)[] s) { foreach (c; s) if (n < into.length) into[n++] = c; }
        void num(size_t v) {
            char[20] d = 0;
            size_t k;
            do { d[k++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0);
            while (k > 0) { k--; put(d[k .. k + 1]); }
        }
        if (f == 0) { put(" 0 files changed"); return into[0 .. n]; }
        put(" "); num(f); put(f == 1 ? " file changed" : " files changed");
        if (ins || del == 0) { put(", "); num(ins); put(ins == 1 ? " insertion(+)" : " insertions(+)"); }
        if (del || ins == 0) { put(", "); num(del); put(del == 1 ? " deletion(-)" : " deletions(-)"); }
        return into[0 .. n];
    }

    // What `git diff <from> <to>` prints, in the part asked for.
    const(char)[] between(const(char)[] from, const(char)[] to, uint context, Shown what, char[] into) return {
        auto before = treeAt(from);
        if (before is null) return null;
        scope (exit) git_tree_free(before);
        auto after = treeAt(to);
        if (after is null) return null;
        scope (exit) git_tree_free(after);
        return printed(before, after, context, what, into);
    }

    // What `git show --unified=0 --format=` prints for a commit: its patch
    // against its parent, or against nothing when it has none.
    const(char)[] show(const(char)[] rev, char[] into) return {
        __gshared char[512] spec = 0;
        if (rev.length + 1 > spec.length) { refuse("the revision is longer than ground holds"); return null; }
        copy(spec[0 .. rev.length], rev);
        spec[rev.length] = 0;
        git_object* obj;
        if (git_revparse_single(&obj, repo, &spec[0]) < 0) { say("the revision would not resolve"); return null; }
        auto c = cast(git_commit*) obj;
        scope (exit) git_object_free(obj);
        // A merge is shown combined, and libgit2 has no combined diff. Against
        // one parent it would be every line the other side brought in.
        overflowed = false;
        if (git_commit_parentcount(c) > 1) return into[0 .. 0];
        git_tree* after;
        if (git_commit_tree(&after, c) < 0) { say("a tree would not read"); return null; }
        scope (exit) git_tree_free(after);
        git_tree* before;
        if (git_commit_parentcount(c) > 0) {
            git_commit* p;
            if (git_commit_parent(&p, c, 0) < 0) { say("a parent would not read"); return null; }
            auto ok = git_commit_tree(&before, p) == 0;
            git_commit_free(p);
            if (!ok) { say("a tree would not read"); return null; }
        }
        scope (exit) if (before !is null) git_tree_free(before);
        return printed(before, after, 0, Shown.patch, into);
    }

    private char[1024] subjectBuf = 0;

    // A commit's subject, as `%s` prints it.
    const(char)[] subject(const(char)[] rev) return {
        __gshared char[512] spec = 0;
        if (rev.length + 1 > spec.length) { refuse("the revision is longer than ground holds"); return null; }
        copy(spec[0 .. rev.length], rev);
        spec[rev.length] = 0;
        git_object* obj;
        if (git_revparse_single(&obj, repo, &spec[0]) < 0) { say("the revision would not resolve"); return null; }
        scope (exit) git_object_free(obj);
        auto s = git_commit_summary(cast(git_commit*) obj);
        if (s is null) return subjectBuf[0 .. 0];
        size_t n;
        while (s[n] != 0 && n < subjectBuf.length) { subjectBuf[n] = s[n]; n++; }
        return subjectBuf[0 .. n];
    }

    private char[1024] nameBuf = 0;

    private const(char)* nameOf(const(char)[] path) {
        size_t start;
        foreach (i, c; path) if (c == '/') start = i + 1;
        auto name = path[start .. $];
        if (name.length == 0 || name.length >= nameBuf.length) return null;
        copy(nameBuf[0 .. name.length], name);
        nameBuf[name.length] = 0;
        return &nameBuf[0];
    }

    private bool worktreeAt(const(char)[] path, git_reference* branch) {
        auto name = nameOf(path);
        if (name is null) { refuse("the tree's path names nothing"); return false; }
        git_worktree_add_options opts;
        if (git_worktree_add_options_init(&opts, GIT_WORKTREE_ADD_OPTIONS_VERSION) < 0) { say("worktree options would not set"); return false; }
        opts.checkout_existing = 1;
        opts.ref_ = branch;
        auto p = z(path);
        if (p is null) { refuse("the path is longer than ground holds"); return false; }
        git_worktree* wt;
        if (git_worktree_add(&wt, repo, name, p, &opts) < 0) { say("the worktree would not be made"); return false; }
        git_worktree_free(wt);
        return true;
    }

    // `git worktree add <path>`: a branch named for the path's last segment,
    // cut from HEAD, or checked out when it is already there.
    bool addWorktree(const(char)[] path) {
        return worktreeAt(path, null);
    }

    // `git branch <branch> $(git commit-tree <empty tree> -m 'ground stage')`
    // and then `git worktree add <path> <branch>`.
    bool addEmptyWorktree(const(char)[] path, const(char)[] branch) {
        git_treebuilder* bld;
        if (git_treebuilder_new(&bld, repo, null) < 0) { say("the empty tree would not build"); return false; }
        git_oid treeId;
        auto wrote = git_treebuilder_write(&treeId, bld);
        git_treebuilder_free(bld);
        if (wrote < 0) { say("the empty tree would not write"); return false; }
        git_tree* tree;
        if (git_tree_lookup(&tree, repo, &treeId) < 0) { say("the empty tree would not read"); return false; }
        scope (exit) git_tree_free(tree);

        git_signature* author, committer;
        if (git_signature_default_from_env(&author, &committer, repo) < 0) { say("no one to sign the commit as"); return false; }
        scope (exit) { git_signature_free(author); git_signature_free(committer); }
        git_oid commitId;
        if (git_commit_create(&commitId, repo, null, author, committer, null, "ground stage\n",
                              tree, 0, null) < 0) { say("the stage commit would not write"); return false; }
        git_commit* commit;
        if (git_commit_lookup(&commit, repo, &commitId) < 0) { say("the stage commit would not read"); return false; }
        scope (exit) git_commit_free(commit);

        __gshared char[1024] name = 0;
        if (branch.length >= name.length) { refuse("the branch name is longer than ground holds"); return false; }
        copy(name[0 .. branch.length], branch);
        name[branch.length] = 0;
        git_reference* made;
        if (git_branch_create(&made, repo, &name[0], commit, 0) < 0) { say("the branch would not be made"); return false; }
        scope (exit) git_reference_free(made);
        return worktreeAt(path, made);
    }

    // `git worktree remove --force <tree>`: the checkout and its record gone,
    // whatever is changed in it.
    bool removeWorktree(const(char)[] tree) {
        auto p = z(tree);
        if (p is null) { refuse("the path is longer than ground holds"); return false; }
        git_repository* there;
        if (git_repository_open_ext(&there, p, 0, null) < 0) { say("the tree would not open"); return false; }
        scope (exit) git_repository_free(there);
        git_worktree* wt;
        if (git_worktree_open_from_repository(&wt, there) < 0) { say("the tree is no worktree"); return false; }
        scope (exit) git_worktree_free(wt);
        git_worktree_prune_options opts;
        if (git_worktree_prune_options_init(&opts, GIT_WORKTREE_PRUNE_OPTIONS_VERSION) < 0) { say("prune options would not set"); return false; }
        opts.flags = GIT_WORKTREE_PRUNE_VALID | GIT_WORKTREE_PRUNE_WORKING_TREE;
        if (git_worktree_prune(wt, &opts) < 0) { say("the worktree would not be removed"); return false; }
        return true;
    }

    private char[41] headBuf = 0;

    // `git rev-parse HEAD`: the whole id. Null when HEAD names no commit.
    const(char)[] headId() return {
        git_oid id;
        if (git_reference_name_to_id(&id, repo, "HEAD") < 0) { say("HEAD would not resolve"); return null; }
        git_oid_fmt(&headBuf[0], &id);
        return headBuf[0 .. 40];
    }

    // `git stash push --include-untracked -m <message>`: 1 stashed, 0 nothing
    // to stash, -1 refused.
    int stashPush(const(char)[] message) {
        git_signature* author, committer;
        if (git_signature_default_from_env(&author, &committer, repo) < 0) { say("no one to stash as"); return -1; }
        scope (exit) { git_signature_free(author); git_signature_free(committer); }
        auto m = z(message);
        if (m is null) { refuse("the message is longer than ground holds"); return -1; }
        git_oid id;
        auto rc = git_stash_save(&id, repo, committer, m, GIT_STASH_INCLUDE_UNTRACKED);
        if (rc == GIT_ENOTFOUND) return 0;
        if (rc < 0) { say("stash"); return -1; }
        return 1;
    }

    // `git stash pop`: the newest stash back on the tree, and dropped. A
    // conflict refuses and keeps the stash, as git does; libgit2's own pop
    // wrote the markers, called it done and dropped the stash.
    bool stashPop() {
        if (git_stash_apply(repo, 0, null) < 0) { say("stash pop"); return false; }
        git_index* index;
        if (git_repository_index(&index, repo) < 0) { say("stash pop: the index would not read"); return false; }
        scope (exit) git_index_free(index);
        if (git_index_read(index, 1) < 0) { say("stash pop: the index would not read"); return false; }
        if (git_index_has_conflicts(index)) { refuse("stash pop: the unstash conflicted, and the stash is kept"); return false; }
        if (git_stash_drop(repo, 0) < 0) { say("stash pop: the stash would not drop"); return false; }
        return true;
    }

    // `git reset --hard <commit>`.
    bool resetHard(const(char)[] commit) {
        git_oid id;
        if (commit.length != 40 || git_oid_fromstrn(&id, commit.ptr, 40) < 0) { refuse("reset: not a whole commit id"); return false; }
        git_object* target;
        if (git_object_lookup(&target, repo, &id, GIT_OBJECT_ANY) < 0) { say("reset"); return false; }
        scope (exit) git_object_free(target);
        if (git_reset(repo, target, GIT_RESET_HARD, null) < 0) { say("reset"); return false; }
        return true;
    }

    // The two-letter codes `git status --porcelain` opens each line with, one a
    // line: HEAD against the index with renames scored as git scores them, then
    // the index against the working tree, joined by path. `??` is untracked.
    const(char)[] statusCodes(char[] into) return {
        git_tree* head;
        git_object* obj;
        auto rc = git_revparse_single(&obj, repo, "HEAD^{tree}");
        if (rc == 0) head = cast(git_tree*) obj;
        else if (rc != GIT_ENOTFOUND && rc != GIT_EUNBORNBRANCH) { say("HEAD's tree would not read"); return null; }
        scope (exit) if (head !is null) git_object_free(cast(git_object*) head);
        git_index* index;
        if (git_repository_index(&index, repo) < 0) { say("the index would not read"); return null; }
        scope (exit) git_index_free(index);

        git_diff_options opts;
        if (!diffOptions(opts)) return null;
        git_diff* staged;
        if (git_diff_tree_to_index(&staged, repo, head, index, &opts) < 0) { say("the index would not diff"); return null; }
        scope (exit) git_diff_free(staged);
        if (findRenames(staged) < 0) { say("renames would not be found"); return null; }

        if (!diffOptions(opts)) return null;
        opts.flags |= GIT_DIFF_INCLUDE_UNTRACKED | GIT_DIFF_INCLUDE_TYPECHANGE;
        git_diff* working;
        if (git_diff_index_to_workdir(&working, repo, index, &opts) < 0) { say("the working tree would not diff"); return null; }
        scope (exit) git_diff_free(working);

        enum MAX = 8192;
        __gshared const(char)*[MAX] paths;
        __gshared char[MAX] xs, ys;
        size_t count;
        static char code(int status) {
            switch (status) {
                case 1: return 'A';
                case 2: return 'D';
                case 3: return 'M';
                case 4: return 'R';
                case 5: return 'C';
                case 7: return '?';
                case 8: return 'T';
                case 10: return 'U';
                default: return ' ';
            }
        }
        foreach (i; 0 .. git_diff_num_deltas(staged)) {
            auto d = git_diff_get_delta(staged, i);
            auto p = pathOf(d);
            // A path deleted and added in one diff changed type.
            if (count > 0 && sameText(paths[count - 1], p)) { xs[count - 1] = 'T'; continue; }
            if (count == MAX) { overflowed = true; break; }
            paths[count] = p;
            xs[count] = code(d.status);
            ys[count] = d.status == 10 ? 'U' : ' ';
            count++;
        }
        size_t untracked;
        foreach (i; 0 .. git_diff_num_deltas(working)) {
            auto d = git_diff_get_delta(working, i);
            if (d.status == 7) { untracked++; continue; }
            auto p = pathOf(d);
            size_t at = count;
            foreach (k; 0 .. count) if (sameText(paths[k], p)) { at = k; break; }
            if (at == count) {
                if (count == MAX) { overflowed = true; break; }
                paths[count] = p;
                xs[count] = ' ';
                count++;
            }
            if (ys[at] != 'U') ys[at] = code(d.status);
        }

        size_t n;
        void line(char x, char y) {
            if (n + 3 > into.length) { overflowed = true; return; }
            if (n > 0) into[n++] = '\n';
            into[n++] = x;
            into[n++] = y;
        }
        foreach (k; 0 .. count) if (xs[k] != ' ' || ys[k] != ' ') line(xs[k], ys[k]);
        foreach (k; 0 .. untracked) line('?', '?');
        return into[0 .. n];
    }

    // `git clean -ffdx`: everything untracked and everything ignored, nested
    // repositories included, gone from the tree.
    bool cleanAll() {
        auto top = root();
        if (top.length == 0) { refuse("clean: no working tree"); return false; }
        git_status_options opts;
        if (git_status_options_init(&opts, GIT_STATUS_OPTIONS_VERSION) < 0) { say("clean"); return false; }
        opts.show = GIT_STATUS_SHOW_WORKDIR_ONLY;
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_INCLUDE_IGNORED;
        git_status_list* list;
        if (git_status_list_new(&list, repo, &opts) < 0) { say("clean"); return false; }
        scope (exit) git_status_list_free(list);
        bool ok = true;
        char[4096] path = 0;
        foreach (i; 0 .. git_status_list_entrycount(list)) {
            auto e = git_status_byindex(list, i);
            if (!(e.status & (GIT_STATUS_WT_NEW | GIT_STATUS_IGNORED)) || e.index_to_workdir is null) continue;
            auto rel = e.index_to_workdir.new_file.path;
            size_t n;
            foreach (c; top) path[n++] = c;
            path[n++] = '/';
            for (size_t k = 0; rel[k] != 0 && n < path.length - 1; k++) path[n++] = rel[k];
            while (n > 1 && path[n - 1] == '/') n--;
            path[n] = 0;
            if (!removeAll(&path[0])) ok = false;
        }
        if (!ok) refuse("clean: not everything could be removed");
        return ok;
    }

    // `git pull --no-rebase --no-edit <remote> <branch>`: the branch fetched
    // and fast-forwarded to, or merged with git's own message. SSH asks the
    // agent, then the keys ~/.ssh/config names; known_hosts is libgit2's check.
    private char[1024] urlBuf = 0;

    // A remote's url as configured, or null when the remote is not there.
    const(char)[] remoteUrl(const(char)[] remoteName) return {
        auto rn = z(remoteName);
        if (rn is null) { refuse("the remote name is too long"); return null; }
        git_remote* remote;
        if (git_remote_lookup(&remote, repo, rn) < 0) { say("no such remote"); return null; }
        scope (exit) git_remote_free(remote);
        size_t ul;
        for (auto u = git_remote_url(remote); u !is null && u[ul] != 0 && ul < urlBuf.length - 1; ul++) urlBuf[ul] = u[ul];
        return urlBuf[0 .. ul];
    }

    // `git fetch <remote>`, with the refspecs it is configured with or the one
    // given. SSH asks the agent, then the keys ~/.ssh/config names.
    bool fetch(const(char)[] remoteName, const(char)* refspec) {
        auto rn = z(remoteName);
        if (rn is null) { refuse("fetch: the remote name is too long"); return false; }
        git_remote* remote;
        if (git_remote_lookup(&remote, repo, rn) < 0) { say("fetch"); return false; }
        scope (exit) git_remote_free(remote);
        __gshared char[1024] url = 0;
        size_t ul;
        for (auto u = git_remote_url(remote); u !is null && u[ul] != 0 && ul < url.length - 1; ul++) url[ul] = u[ul];

        __gshared Asking asking;
        asking.tried = 0;
        asking.count = 0;
        {
            import core.stdc.stdlib : getenv;
            import core.stdc.stdio : fopen, fread, fclose;
            auto h = getenv("HOME");
            size_t hl;
            if (h !is null) while (h[hl] != 0) hl++;
            const(char)[] home = h is null ? "" : h[0 .. hl];
            char[1024] cfgPath = 0;
            size_t cn;
            foreach (c; home) cfgPath[cn++] = c;
            foreach (c; "/.ssh/config") cfgPath[cn++] = c;
            char[16384] cfg = 0;
            size_t got;
            auto f = fopen(&cfgPath[0], "rb");
            if (f !is null) { got = fread(&cfg[0], 1, cfg.length, f); fclose(f); }
            foreach (i; 0 .. 8) asking.keys[i] = asking.bufs[i][];
            asking.count = identityFiles(cfg[0 .. got], hostOf(url[0 .. ul]), home, asking.keys[]);
        }

        git_fetch_options fo;
        if (git_fetch_options_init(&fo, GIT_FETCH_OPTIONS_VERSION) < 0) { say("fetch"); return false; }
        fo.callbacks.credentials = &askCredential;
        fo.callbacks.payload = &asking;

        char*[1] specs = [cast(char*) refspec];
        git_strarray arr = git_strarray(&specs[0], 1);
        if (git_remote_fetch(remote, refspec is null ? null : &arr, &fo, null) < 0) { say("fetch"); return false; }
        return true;
    }

    // What `git log --oneline <hide>..<show>` prints, a commit a line, newest
    // first. Null when either end does not resolve.
    const(char)[] oneline(const(char)[] hide, const(char)[] show, char[] into) return {
        git_oid h, s;
        __gshared char[1024] spec = 0;
        bool resolve(const(char)[] rev, ref git_oid id) {
            if (rev.length >= spec.length) return false;
            copy(spec[0 .. rev.length], rev);
            spec[rev.length] = 0;
            git_object* obj;
            if (git_revparse_single(&obj, repo, &spec[0]) < 0) return false;
            id = *git_object_id(obj);
            git_object_free(obj);
            return true;
        }
        if (!resolve(hide, h) || !resolve(show, s)) { say("log: a revision would not resolve"); return null; }
        git_revwalk* walk;
        if (git_revwalk_new(&walk, repo) < 0) { say("log"); return null; }
        scope (exit) git_revwalk_free(walk);
        git_revwalk_sorting(walk, GIT_SORT_TIME);
        if (git_revwalk_push(walk, &s) < 0 || git_revwalk_hide(walk, &h) < 0) { say("log"); return null; }

        size_t n;
        git_oid id;
        while (git_revwalk_next(&id, walk) == 0) {
            git_commit* c;
            if (git_commit_lookup(&c, repo, &id) < 0) { say("log: a commit would not read"); return null; }
            scope (exit) git_commit_free(c);
            auto sha = abbreviated(id);
            auto title = git_commit_summary(c);
            size_t tl;
            while (title !is null && title[tl] != 0) tl++;
            if (n + sha.length + tl + 2 > into.length) { overflowed = true; break; }
            if (n > 0) into[n++] = '\n';
            copy(into[n .. n + sha.length], sha);
            n += sha.length;
            into[n++] = ' ';
            if (tl > 0) { copy(into[n .. n + tl], title[0 .. tl]); n += tl; }
        }
        return into[0 .. n];
    }

    private char[41] abbrevBuf = 0;

    // An id at git's own abbreviation, unique in this repository.
    private const(char)[] abbreviated(git_oid id) return {
        char[40] hex;
        git_oid_fmt(&hex[0], &id);
        size_t len = abbrevLength();
        git_odb* odb;
        if (len < 40 && git_repository_odb(&odb, repo) == 0) {
            scope (exit) git_odb_free(odb);
            for (; len < 40; len++) {
                git_oid prefix, full;
                git_oid_fromstrn(&prefix, &hex[0], len);
                if (git_odb_exists_prefix(&full, odb, &prefix, len) != GIT_EAMBIGUOUS) break;
            }
        }
        copy(abbrevBuf[0 .. len], hex[0 .. len]);
        return abbrevBuf[0 .. len];
    }

    bool pull(const(char)[] remoteName, const(char)[] branch) {
        auto known = remoteUrl(remoteName);
        if (known is null) { say("pull: no such remote"); return false; }
        __gshared char[1024] url = 0;
        size_t ul = known.length;
        copy(url[0 .. ul], known);

        __gshared char[2048] spec = 0;
        size_t sn;
        void put(const(char)[] s) { foreach (c; s) if (sn < spec.length - 1) spec[sn++] = c; }
        put("+refs/heads/"); put(branch); put(":refs/remotes/"); put(remoteName); put("/"); put(branch);
        spec[sn] = 0;
        if (!fetch(remoteName, &spec[0])) { say("pull: fetch"); return false; }

        __gshared char[1024] tracking = 0;
        size_t tn;
        foreach (c; "refs/remotes/") tracking[tn++] = c;
        foreach (c; remoteName) tracking[tn++] = c;
        tracking[tn++] = '/';
        foreach (c; branch) if (tn < tracking.length - 1) tracking[tn++] = c;
        tracking[tn] = 0;
        git_oid theirs;
        if (git_reference_name_to_id(&theirs, repo, &tracking[0]) < 0) { say("pull: the fetched branch is not there"); return false; }

        git_annotated_commit* their;
        if (git_annotated_commit_lookup(&their, repo, &theirs) < 0) { say("pull"); return false; }
        scope (exit) git_annotated_commit_free(their);
        const(git_annotated_commit)*[1] heads = [their];
        uint analysis, preference;
        if (git_merge_analysis(&analysis, &preference, repo, &heads[0], 1) < 0) { say("pull: merge analysis"); return false; }
        if (analysis & GIT_MERGE_ANALYSIS_UP_TO_DATE) return true;

        bool ff = (analysis & (GIT_MERGE_ANALYSIS_FASTFORWARD | GIT_MERGE_ANALYSIS_UNBORN)) != 0
                  && !(preference & GIT_MERGE_PREFERENCE_NO_FASTFORWARD);
        if (ff) {
            git_object* target;
            if (git_object_lookup(&target, repo, &theirs, GIT_OBJECT_ANY) < 0) { say("pull"); return false; }
            scope (exit) git_object_free(target);
            if (git_checkout_tree(repo, target, null) < 0) { say("pull: checkout"); return false; }
            git_reference* head;
            if (git_repository_head(&head, repo) < 0) { say("pull: HEAD"); return false; }
            scope (exit) git_reference_free(head);
            __gshared char[2048] log = 0;
            size_t ln;
            foreach (c; "pull ") log[ln++] = c;
            foreach (c; remoteName) log[ln++] = c;
            log[ln++] = ' ';
            foreach (c; branch) if (ln < log.length - 32) log[ln++] = c;
            foreach (c; ": Fast-forward") log[ln++] = c;
            log[ln] = 0;
            git_reference* moved;
            if (git_reference_set_target(&moved, head, &theirs, &log[0]) < 0) { say("pull: the branch would not move"); return false; }
            git_reference_free(moved);
            return true;
        }
        if (preference & GIT_MERGE_PREFERENCE_FASTFORWARD_ONLY) { refuse("pull: not possible to fast-forward"); return false; }

        if (git_merge(repo, &heads[0], 1, null, null) < 0) { say("pull: merge"); return false; }
        git_index* index;
        if (git_repository_index(&index, repo) < 0) { say("pull: index"); return false; }
        scope (exit) git_index_free(index);
        if (git_index_has_conflicts(index)) { refuse("pull: the merge conflicted"); return false; }
        git_oid treeId;
        if (git_index_write_tree(&treeId, index) < 0) { say("pull: the merged tree would not write"); return false; }
        git_tree* tree;
        if (git_tree_lookup(&tree, repo, &treeId) < 0) { say("pull"); return false; }
        scope (exit) git_tree_free(tree);

        git_oid ours;
        if (git_reference_name_to_id(&ours, repo, "HEAD") < 0) { say("pull: HEAD"); return false; }
        git_commit* oc, tc;
        if (git_commit_lookup(&oc, repo, &ours) < 0) { say("pull"); return false; }
        scope (exit) git_commit_free(oc);
        if (git_commit_lookup(&tc, repo, &theirs) < 0) { say("pull"); return false; }
        scope (exit) git_commit_free(tc);
        const(git_commit)*[2] parents = [oc, tc];

        git_signature* author, committer;
        if (git_signature_default_from_env(&author, &committer, repo) < 0) { say("pull: no one to sign the merge as"); return false; }
        scope (exit) { git_signature_free(author); git_signature_free(committer); }

        auto msg = mergeMessage(branch, url[0 .. ul]);
        git_oid made;
        if (git_commit_create(&made, repo, "HEAD", author, committer, null, msg.ptr, tree, 2, &parents[0]) < 0) {
            say("pull: the merge commit would not write");
            return false;
        }
        git_repository_state_cleanup(repo);
        return true;
    }

    private char[2048] msgBuf = 0;

    // What fmt-merge-msg writes for one branch pulled from a remote: the url as
    // fetch records it, and `into <branch>` unless merge.suppressDest covers it.
    const(char)[] mergeMessage(const(char)[] branch, const(char)[] url) return {
        size_t n;
        void put(const(char)[] s) { foreach (c; s) if (n < msgBuf.length - 2) msgBuf[n++] = c; }
        put("Merge branch '");
        put(branch);
        put("' of ");
        put(fetchedUrl(url));

        git_reference* head;
        if (git_repository_head(&head, repo) == 0) {
            scope (exit) git_reference_free(head);
            auto full = git_reference_name(head);
            size_t fl;
            while (full[fl] != 0) fl++;
            auto name = full[0 .. fl];
            enum heads = "refs/heads/";
            if (name.length > heads.length && name[0 .. heads.length] == heads) name = name[heads.length .. $];
            if (!destSuppressed(name)) { put(" into "); put(name); }
        }
        msgBuf[n++] = '\n';
        msgBuf[n] = 0;
        return msgBuf[0 .. n];
    }

    private bool destSuppressed(const(char)[] branch) {
        char[512] b = 0;
        if (branch.length >= b.length) return false;
        copy(b[0 .. branch.length], branch);
        git_config* cfg;
        if (git_repository_config_snapshot(&cfg, repo) == 0) {
            scope (exit) git_config_free(cfg);
            const(char)* v;
            if (git_config_get_string(&v, cfg, "merge.suppressDest") == 0 && v !is null) {
                version (OSX) enum FNM_PATHNAME = 0x02; else enum FNM_PATHNAME = 0x01;
                return fnmatch(v, &b[0], FNM_PATHNAME) == 0;
            }
        }
        return branch == "main" || branch == "master";
    }

    // What `git diff --cached --name-only` will name once `adds`, and commit
    // -a when `all`, have run: applied to the index in memory, read against
    // HEAD, thrown away. The index on disk is never written.
    const(char)[] stagedAfter(const(Adding)[] adds, bool all, char[] into) return {
        git_tree* head;
        git_object* obj;
        auto rc = git_revparse_single(&obj, repo, "HEAD^{tree}");
        if (rc == 0) head = cast(git_tree*) obj;
        else if (rc != GIT_ENOTFOUND && rc != GIT_EUNBORNBRANCH) { say("HEAD's tree would not read"); return null; }
        scope (exit) if (head !is null) git_object_free(cast(git_object*) head);

        git_index* index;
        if (git_repository_index(&index, repo) < 0) { say("the index would not read"); return null; }
        // Back to what is on disk, so nothing applied here outlives this call.
        scope (exit) { git_index_read(index, 1); git_index_free(index); }

        __gshared char[1024][16] specBufs;
        __gshared char*[16] specPtrs;
        foreach (ref a; adds) {
            size_t count;
            bool whole;
            foreach (spec; a.specs) {
                if (count == specPtrs.length) { refuse("more paths in one add than ground holds"); return null; }
                auto len = joinSpec(a.base, spec, specBufs[count][]);
                if (len == 0) { whole = true; continue; }
                specPtrs[count] = &specBufs[count][0];
                count++;
            }
            if (a.specs.length == 0 && !a.update) continue;
            git_strarray paths = git_strarray(&specPtrs[0], count);
            auto pathspec = (whole || a.specs.length == 0) ? null : &paths;
            if (!a.update && git_index_add_all(index, pathspec, GIT_INDEX_ADD_DEFAULT, null, null) < 0) { say("add"); return null; }
            if (git_index_update_all(index, pathspec, null, null) < 0) { say("add"); return null; }
        }
        if (all && git_index_update_all(index, null, null, null) < 0) { say("commit -a"); return null; }

        git_diff_options opts;
        if (!diffOptions(opts)) return null;
        git_diff* diff;
        if (git_diff_tree_to_index(&diff, repo, head, index, &opts) < 0) { say("the index would not diff"); return null; }
        scope (exit) git_diff_free(diff);
        if (findRenames(diff) < 0) { say("renames would not be found"); return null; }
        size_t n;
        if (!namesOf(diff, into, n)) return null;
        return into[0 .. n];
    }

    // What `git ls-files` prints: every index entry's path in byte order, a
    // conflicted path once for each of its stages. libgit2 keeps the index
    // ignoring case where core.ignorecase is set, and git prints it bytewise.
    const(char)[] tracked(char[] into) return {
        import core.stdc.stdlib : malloc, free, qsort;
        git_index* index;
        if (git_repository_index(&index, repo) < 0) { say("the index would not read"); return null; }
        scope (exit) git_index_free(index);
        auto count = git_index_entrycount(index);
        auto entries = cast(const(git_index_entry)**) malloc((count + 1) * (void*).sizeof);
        if (entries is null) { refuse("no memory to sort the index"); return null; }
        scope (exit) free(entries);
        foreach (i; 0 .. count) entries[i] = git_index_get_byindex(index, i);
        qsort(entries, count, (void*).sizeof, &entryOrder);
        size_t n;
        foreach (i; 0 .. count) {
            auto p = entries[i].path;
            size_t len;
            while (p[len] != 0) len++;
            if (n + len + 1 > into.length) { refuse("more files than ground holds"); return null; }
            if (n > 0) into[n++] = '\n';
            foreach (c; p[0 .. len]) into[n++] = c;
        }
        return into[0 .. n];
    }

    // What `git describe --tags --always` prints for HEAD: the nearest tag,
    // lightweight or not, with the distance and id past it, or the id alone.
    const(char)[] describeHead(char[] into) return {
        git_object* head;
        if (git_revparse_single(&head, repo, "HEAD") < 0) { say("HEAD would not resolve"); return null; }
        scope (exit) git_object_free(head);
        git_describe_options opts;
        if (git_describe_options_init(&opts, 1) < 0) { say("describe"); return null; }
        opts.describe_strategy = GIT_DESCRIBE_TAGS;
        opts.show_commit_oid_as_fallback = 1;
        git_describe_result* result;
        if (git_describe_commit(&result, head, &opts) < 0) { say("describe"); return null; }
        scope (exit) git_describe_result_free(result);
        git_describe_format_options format;
        if (git_describe_format_options_init(&format, 1) < 0) { say("describe"); return null; }
        format.abbreviated_size = cast(uint) abbrevLength();
        git_buf buf;
        scope (exit) git_buf_dispose(&buf);
        if (git_describe_format(&buf, result, &format) < 0) { say("describe"); return null; }
        if (buf.size > into.length) { refuse("the description is longer than ground holds"); return null; }
        copy(into[0 .. buf.size], buf.ptr[0 .. buf.size]);
        return into[0 .. buf.size];
    }

    // Whether both refs are there and name one commit, as the two lines
    // for-each-ref printed for them agreed.
    bool refsAgree(const(char)[] a, const(char)[] b) {
        git_oid x, y;
        auto pa = z(a);
        if (pa is null || git_reference_name_to_id(&x, repo, pa) < 0) return false;
        auto pb = z(b);
        if (pb is null || git_reference_name_to_id(&y, repo, pb) < 0) return false;
        return git_oid_equal(&x, &y) != 0;
    }

    private char[41] shortBuf = 0;

    // The commit a ref names, as `%(objectname:short)` prints it: core.abbrev's
    // length, or git's own from how many objects are packed, then longer until
    // no other object shares it. Null when the ref is not there.
    const(char)[] shortId(const(char)[] refname) return {
        git_oid id;
        auto p = z(refname);
        if (p is null || git_reference_name_to_id(&id, repo, p) < 0) return null;
        auto s = abbreviated(id);
        copy(shortBuf[0 .. s.length], s);
        return shortBuf[0 .. s.length];
    }

    // core.abbrev when set; else git's auto length: half the bits of the
    // packed object count, rounded up, and never under seven.
    private size_t abbrevLength() {
        git_config* cfg;
        if (git_repository_config_snapshot(&cfg, repo) == 0) {
            scope (exit) git_config_free(cfg);
            const(char)* v;
            if (git_config_get_string(&v, cfg, "core.abbrev") == 0 && v !is null) {
                size_t n;
                while (v[n] != 0) n++;
                auto s = v[0 .. n];
                if (s == "no") return 40;
                if (s != "auto") {
                    size_t num;
                    foreach (c; s) { if (c < '0' || c > '9') { num = 0; break; } num = num * 10 + (c - '0'); }
                    if (num >= 4) return num > 40 ? 40 : num;
                }
            }
        }
        ulong count = packedObjects(git_repository_commondir(repo));
        size_t bit = 0;
        for (auto v = count; v >>= 1; ) bit++;
        size_t len = (bit + 1 + 1) / 2;
        return len < 7 ? 7 : len;
    }

    // 1 when check-ignore would name the path, 0 when not, -1 when libgit2
    // refused. A tracked file is never ignored. An absolute path inside the
    // tree is asked as the tree names it.
    int ignored(const(char)[] path) {
        auto r = root();
        if (r.length > 0 && path.length > r.length + 1 && path[0 .. r.length] == r && path[r.length] == '/')
            path = path[r.length + 1 .. $];
        auto p = z(path);
        if (p is null) { refuse("the path is longer than ground holds"); return -1; }

        git_index* index;
        if (git_repository_index(&index, repo) < 0) { say("the index would not read"); return -1; }
        auto tracked = git_index_get_bypath(index, p, 0) !is null;
        git_index_free(index);
        if (tracked) return 0;

        int yes;
        if (git_ignore_path_is_ignored(&yes, repo, p) < 0) { say("the ignore rules would not read"); return -1; }
        return yes != 0 ? 1 : 0;
    }

    private int sideOf(const(git_commit)* c, const(char)* path, ref Side s) {
        git_tree* t;
        auto rc = git_commit_tree(&t, c);
        if (rc < 0) return rc;
        scope (exit) git_tree_free(t);
        git_tree_entry* e;
        rc = git_tree_entry_bypath(&e, t, path);
        if (rc == GIT_ENOTFOUND) { s.present = false; return 0; }
        if (rc < 0) return rc;
        s.present = true;
        s.id = *git_tree_entry_id(e);
        s.mode = git_tree_entry_filemode(e);
        git_tree_entry_free(e);
        return 0;
    }

    // The commit `git log -1 -- <name>` shows, walked from HEAD the way its
    // default history simplification walks: a merge the file came through
    // unchanged is followed to the first parent that has it the same.
    Last lastTouched(const(char)[] name) {
        Last last;
        auto path = z(name);
        if (path is null) { refuse("the name is longer than ground holds"); return last; }

        git_oid head;
        auto rc = git_reference_name_to_id(&head, repo, "HEAD");
        if (rc == GIT_ENOTFOUND || rc == GIT_EUNBORNBRANCH) { last.ok = true; return last; }
        if (rc < 0) { say("HEAD would not resolve"); return last; }

        git_commit* cur;
        if (git_commit_lookup(&cur, repo, &head) < 0) { say("HEAD's commit would not read"); return last; }
        Side cs;
        if (sideOf(cur, path, cs) < 0) { git_commit_free(cur); say("a tree would not read"); return last; }

        for (;;) {
            auto parents = git_commit_parentcount(cur);
            if (parents == 0) {
                last.since = cs.present ? git_commit_time(cur) : 0;
                break;
            }
            git_commit* follow;
            Side fs;
            foreach (i; 0 .. parents) {
                git_commit* p;
                if (git_commit_parent(&p, cur, i) < 0) { git_commit_free(cur); say("a parent would not read"); return last; }
                Side ps;
                if (sideOf(p, path, ps) < 0) {
                    git_commit_free(p);
                    git_commit_free(cur);
                    say("a tree would not read");
                    return last;
                }
                if (same(cs, ps)) { follow = p; fs = ps; break; }
                git_commit_free(p);
            }
            if (follow is null) {
                last.since = git_commit_time(cur);
                break;
            }
            git_commit_free(cur);
            cur = follow;
            cs = fs;
        }
        git_commit_free(cur);
        last.ok = true;
        return last;
    }
}
