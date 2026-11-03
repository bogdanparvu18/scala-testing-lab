package lab

import zio.*
import zio.json.*
import java.nio.file.{Files, Paths, StandardCopyOption}

/** Runtime I/O uses local files and loopback PostgreSQL/product-search connections. */
object Main extends ZIOAppDefault:
  private def readInput(path: String): Task[AstRequest] = ZIO.attemptBlocking {
    val raw = Files.readString(Paths.get(path))
    val a = raw.fromJson[AstRequest].fold(e => throw new IllegalArgumentException(e), identity)
    InputValidation.validate(a)
    a
  }
  private def writeJson(path: String, text: String): Task[Unit] = ZIO.attemptBlocking {
    val dest = Paths.get(path).toAbsolutePath
    Files.createDirectories(dest.getParent)
    val tmp = Files.createTempFile(dest.getParent, ".resolution-", ".tmp")
    try
      Files.writeString(tmp, text + "\n")
      try Files.move(tmp, dest, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
      catch case _: java.nio.file.AtomicMoveNotSupportedException =>
        Files.move(tmp, dest, StandardCopyOption.REPLACE_EXISTING)
    finally Files.deleteIfExists(tmp)
    ()
  }

  def run = getArgs.flatMap { args =>
    args.toList match
      case "serve-products" :: portText :: Nil => ZIO.scoped {
        for
          port <- ZIO.attempt {
            val value=portText.toInt
            require(value > 0 && value <= 65535,"Product-search port must be between 1 and 65535")
            value
          }
          store <- PostgresStore.open
          boundPort <- ProductSearchService.start(port,store.searchProducts)
          _ <- Console.printLine(s"Product search ready at http://127.0.0.1:$boundPort/products; leave this process running for editor autocomplete.")
          _ <- ZIO.never
        yield ()
      }
      case "import-product-attributes" :: dir :: release :: Nil => ZIO.scoped {
        for
          prepared <- ZIO.attemptBlocking(ProductAttributes.prepare(Paths.get(dir),release))
          store <- PostgresStore.open
          summary <- store.importProductAttributes(prepared)
          _ <- Console.printLine(summary)
        yield ()
      }
      case "import-rxnorm" :: dir :: release :: Nil => ZIO.scoped {
        for
          prepared <- ZIO.attemptBlocking(Rrf.prepare(Paths.get(dir), release))
          _ <- Console.printLine(s"Prepared ${prepared.concepts.size} canonical concepts for $release; streaming names and relationships into local PostgreSQL.")
          store <- PostgresStore.open
          summary <- store.importIndex(prepared)
          _ <- Console.printLine(s"Index ready: $summary. Identical input can be safely re-imported.")
        yield ()
      }
      case "resolve" :: input :: output :: Nil => ZIO.scoped {
        for
          ast <- readInput(input)
          store <- PostgresStore.open
          snapshot <- store.snapshotForResolution(ast)
          report <- ZIO.attempt(Resolver.resolve(ast, snapshot))
          runId = Hashing.sha256(report.inputSha256 + report.snapshotFingerprint + report.policyVersion + Hashing.sha256(report.toJson))
          _ <- store.saveBinding(runId, ast.toJson, report.toJson, snapshot.release)
          _ <- writeJson(output, report.toJsonPretty)
          _ <- Console.printLine(s"Saved $output; binding run $runId; " + report.resolutions.map(r => s"${r.mention.id}=${r.status}").mkString(", "))
        yield ()
      }
      case "lookup" :: release :: terms if terms.nonEmpty => ZIO.scoped {
        for
          store <- PostgresStore.open
          query = terms.mkString(" ")
          snapshot <- store.snapshot(release, Vector(query))
          matches <- ZIO.attempt(Resolver.candidates(query,snapshot))
          status = if matches.isEmpty then "unresolved" else if matches.size == 1 then "matched" else "ambiguous"
          report = LookupReport(query,release,snapshot.scope,Hashing.fingerprint(snapshot),status,matches)
          _ <- Console.printLine(report.toJsonPretty)
        yield ()
      }
      case "inspect-rxnorm" :: dir :: release :: Nil =>
        ZIO.attemptBlocking {
          val p = Rrf.prepare(Paths.get(dir), release)
          var descriptions = 0L
          var relationships = 0L
          p.foreachDescription(_ => descriptions += 1)
          p.foreachRelation(_ => relationships += 1)
          p.verifyUnchanged()
          s"Release $release; scope ${Rrf.scope}; ${p.concepts.size} concepts; $descriptions names; $relationships relationship rows; source SHA-256 ${p.sha256.toJson}"
        }.flatMap(Console.printLine(_))
      case _ => ZIO.fail(new IllegalArgumentException(
        "Usage: import-rxnorm <rrf-dir> <YYYY-MM-DD> | resolve <ast.json> <result.json> | " +
        "lookup <release> <name> | serve-products <port> | inspect-rxnorm <rrf-dir> <release> | import-product-attributes <rrf-dir> <release>. No seed or alias argument is accepted."))
  }
