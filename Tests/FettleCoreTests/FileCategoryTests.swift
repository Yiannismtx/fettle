import Testing
import Foundation
@testable import FettleCore

@Suite("File classification")
struct FileCategoryTests {
    @Test("Installer extensions land in Installers, not Archives")
    func installers() {
        #expect(FileCategory.classify(fileName: "Xcode.dmg") == .installers)
        #expect(FileCategory.classify(fileName: "Node.pkg") == .installers)
        #expect(FileCategory.classify(fileName: "Thing.mpkg") == .installers)
    }

    @Test("Archives")
    func archives() {
        #expect(FileCategory.classify(fileName: "src.zip") == .archives)
        #expect(FileCategory.classify(fileName: "src.tar.gz") == .archives)
        #expect(FileCategory.classify(fileName: "backup.7z") == .archives)
    }

    @Test("Images, including formats UTType alone gets wrong")
    func images() {
        #expect(FileCategory.classify(fileName: "shot.png") == .images)
        #expect(FileCategory.classify(fileName: "photo.HEIC") == .images)
        #expect(FileCategory.classify(fileName: "logo.svg") == .images)
        #expect(FileCategory.classify(fileName: "anim.webp") == .images)
    }

    @Test("Documents")
    func documents() {
        #expect(FileCategory.classify(fileName: "paper.pdf") == .documents)
        #expect(FileCategory.classify(fileName: "notes.md") == .documents)
        #expect(FileCategory.classify(fileName: "data.csv") == .documents)
        #expect(FileCategory.classify(fileName: "deck.key") == .documents)
    }

    @Test("Media and unknown extensions fall through to Other, not Documents")
    func other() {
        #expect(FileCategory.classify(fileName: "clip.mp4") == .other)
        #expect(FileCategory.classify(fileName: "song.mp3") == .other)
        #expect(FileCategory.classify(fileName: "noextension") == .other)
        #expect(FileCategory.classify(fileName: "thing.zzzzz") == .other)
    }

    @Test("Classification is case-insensitive")
    func caseInsensitive() {
        #expect(FileCategory.classify(fileName: "Installer.DMG") == .installers)
        #expect(FileCategory.classify(fileName: "A.ZIP") == .archives)
    }
}
