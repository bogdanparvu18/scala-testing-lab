ThisBuild / scalaVersion := "3.5.1"
ThisBuild / organization := "com.bogdanparvu.lab"
ThisBuild / version := "0.3.0-SNAPSHOT"

lazy val root = project.in(file("."))
  .settings(
    name := "scala-testing-lab",
    libraryDependencies ++= Seq(
      "dev.zio" %% "zio" % "2.1.9",
      "dev.zio" %% "zio-json" % "0.7.3",
      "org.postgresql" % "postgresql" % "42.7.14",
      "dev.zio" %% "zio-test" % "2.1.9" % Test,
      "dev.zio" %% "zio-test-sbt" % "2.1.9" % Test
    ),
    testFrameworks += new TestFramework("zio.test.sbt.ZTestFramework"),
    Compile / mainClass := Some("lab.Main"),
    // ZIO's sbt detection expects "/sbt-launch.jar" in the classpath and can miss
    // Windows paths or other launcher names. Isolate CLI exits so bootstrap can
    // finish both imports and both resolution checks in the same sbt queue.
    Compile / run / fork := true,
    Compile / run / javaOptions += "-Xmx2G",
    Compile / run / outputStrategy := Some(StdoutOutput),
    Test / parallelExecution := false,
    scalacOptions ++= Seq("-deprecation", "-feature", "-unchecked")
  )
