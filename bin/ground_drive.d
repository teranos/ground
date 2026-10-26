module ground_drive;

// "and the driver has the same story."
import ritual : handleDrive;

extern (C) int main(int argc, const(char)** argv) {
    return handleDrive(argc, argv);
}
