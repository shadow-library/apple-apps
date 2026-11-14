import ProjectDescription

public enum Organization {
  public static let name = "Shadow Library"
  public static let bundleIdPrefix = "com.shadowlibrary"
  public static let minimumOSVersion = "26.0"

  public static let developmentTeam = Environment.developmentTeam.getString(default: "")
}
