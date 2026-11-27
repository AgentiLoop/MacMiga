import Testing
@testable import MacMigaCore

@Test func fileNameTagsGiveTheVideoStandard() {
    #expect(VideoStandard.ntsc(fileName: "Lemmings (1991)(Psygnosis)(NTSC).adf") == true)
    #expect(VideoStandard.ntsc(fileName: "Game [NTSC].adf") == true)
    #expect(VideoStandard.ntsc(fileName: "Turrican (1990)(Rainbow Arts)(PAL)[cr].adf") == false)
    #expect(VideoStandard.ntsc(fileName: "Amiga Boulder Dash (1993)(PD)[KS2.0].adf") == nil)
    #expect(VideoStandard.ntsc(fileName: "Palace.adf") == nil) // a word, not a tag
}
