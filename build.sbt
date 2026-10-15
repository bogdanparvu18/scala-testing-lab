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
    Test / parallelExecution := false,
    scalacOptions ++= Seq("-deprecation", "-feature", "-unchecked")
  )
