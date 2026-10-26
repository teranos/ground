module ground_code;

// "similarily i want ground code to be split off from the hooks as well"
import code : handleCode;

extern (C) int main() {
    return handleCode();
}
