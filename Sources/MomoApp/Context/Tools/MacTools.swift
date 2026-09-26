import Foundation
import MomoKit

/// Tools that let Momo work across the Mac: files, Apple apps, system controls, power tools
/// and awareness of what the user is looking at.
enum MacTools {
    static func all() -> [any MomoTool] {
        FileTools.all()
    }
}
