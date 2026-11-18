import Foundation

FileHandle.standardError.write(Data("usage: NovelForgeEval <command>\n".utf8))
exit(EX_USAGE)
