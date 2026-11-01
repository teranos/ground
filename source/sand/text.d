module sand.text;

// "a true agnostic ground, and then only the compiled controls being their own thing shipped to the user"

// The pbt the controls compile from. An engine (-d-version=Floor) is built from the floor, ground's
// tracked controls alone, the same for everyone; make sand builds a sand from everything wind gathered.
version (Floor) enum SAND_TEXT = import(".ctfe/floor");
else enum SAND_TEXT = import(".ctfe/sand");
