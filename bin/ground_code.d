module ground_code;

// "similarily i want ground code to be split off from the hooks as well"
import code : handleCode;

// A D main, so the D runtime is started: ground code is not -betterC.
int main() {
    return handleCode();
}
