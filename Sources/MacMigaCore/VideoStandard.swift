/// Whether a disk was made for an NTSC (60 Hz) or a PAL (50 Hz) Amiga, as far as its file
/// name tells: TOSEC and most collections tag images `(NTSC)` or `(PAL)`.
///
/// Nothing on a disk or in what a game shows says which standard it was made for: a test of
/// the picture's size (a game made for NTSC fits the 262-line NTSC frame) also caught 7 of 12
/// PAL games, such as Lotus and Nicky Boom, whose screens are just as short. So untagged disks
/// are left to the user, whose choice the app remembers per disk.
public enum VideoStandard {
    /// True for a file name tagged NTSC, false for one tagged PAL, nil when it has neither.
    public static func ntsc(fileName: String) -> Bool? {
        let words = fileName.lowercased().split { !$0.isLetter && !$0.isNumber }
        if words.contains("ntsc") { return true }
        if words.contains("pal") { return false }
        return nil
    }
}
