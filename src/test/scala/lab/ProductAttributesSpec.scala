package lab

import java.nio.file.{Files,StandardOpenOption}
import scala.jdk.CollectionConverters.*
import zio.*
import zio.test.*

object ProductAttributesSpec extends ZIOSpecDefault:
  private def fixture[A](f: java.nio.file.Path => A): Task[A] =
    ZIO.acquireReleaseWith(ZIO.attempt(Files.createTempDirectory("rxnsat-test-")))(dir => ZIO.attempt {
      val stream=Files.walk(dir)
      try stream.iterator.asScala.toVector.reverse.foreach(Files.deleteIfExists(_)) finally stream.close()
    }.orDie) { dir => ZIO.attempt {
      Files.writeString(dir.resolve("RXNCONSO.RRF"),"base conso fixture\n")
      Files.writeString(dir.resolve("RXNREL.RRF"),"base relation fixture\n")
      Files.writeString(dir.resolve("RXNSAT.RRF"),Vector("10","","","20","AUI","","AT1","","RXN_STRENGTH","RXNORM","500 MG","N","").mkString("|")+"|\n")
      f(dir)
    }}
  def spec = suite("RXNSAT import plan")(
    test("retains all 13 original fields and pins all three source hashes") {
      fixture { dir =>
        val prepared=ProductAttributes.prepare(dir,"2026-10-05")
        var row=Vector.empty[String]
        prepared.foreachRow(x => row=x.toVector)
        assertTrue(row.size == 13,row(10) == "500 MG",row(1).isEmpty,prepared.sha256.size == 3)
      }
    },
    test("rejects malformed rows while streaming") {
      fixture { dir =>
        Files.writeString(dir.resolve("RXNSAT.RRF"),"bad|row|\n",StandardOpenOption.APPEND)
        val p=ProductAttributes.prepare(dir,"2026-10-05")
        assertTrue(scala.util.Try(p.foreachRow(_ => ())).isFailure)
      }
    },
    test("rejects a modified source after preparation") {
      fixture { dir =>
        val p=ProductAttributes.prepare(dir,"2026-10-05")
        Files.writeString(dir.resolve("RXNREL.RRF"),"changed",StandardOpenOption.APPEND)
        assertTrue(scala.util.Try(p.verifyUnchanged()).isFailure)
      }
    }
  )
