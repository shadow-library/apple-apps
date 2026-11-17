import Foundation
import NovelForgeCore

enum StoryRoute: Hashable {
  case volume(String)
  case milestone(String)
  case promise(PromiseRef)
  case secret(String)
}
