import ProjectDescription

public enum Organization {
  public static let name = "Shadow Library"
  public static let appBundleIdPrefix = "com.shadow.apps"
  public static let libraryBundleIdPrefix = "com.shadow.library"
  public static let minimumOSVersion = "26.0"

  public static let developmentTeam = Environment.developmentTeam.getString(default: "")
}
