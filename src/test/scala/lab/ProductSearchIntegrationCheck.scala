package lab

import java.net.URI
import java.net.http.{HttpClient,HttpRequest,HttpResponse}
import java.nio.file.{Files,Path}
import java.sql.DriverManager
import scala.collection.immutable.ListMap
import scala.jdk.CollectionConverters.*
import scala.util.Using
import zio.*
import zio.json.*

/** Opt-in real PostgreSQL/HTTP check. Only fictional terminology is generated. */
object ProductSearchIntegrationCheck extends ZIOAppDefault:
  private val release="2099-03-01"
  private val otherRelease="2099-03-02"
  private def name(cui: String,aui: String,tty: String,value: String,sab: String = "RXNORM"): String =
    val values=Array.fill(18)("")
    Vector(0->cui,1->"ENG",7->aui,11->sab,12->tty,14->value,16->"N").foreach((i,v) => values(i)=v)
    values.mkString("|")+"|\n"
  private def fixture: Task[Path] = ZIO.attemptBlocking {
    val dir=Files.createTempDirectory("synthetic-product-search-")
    Files.writeString(dir.resolve("RXNCONSO.RRF"),
      name("100","1","SCD","synthetic generic product")+
      name("100","2","SY","ASPI synonym","TEST_SOURCE")+
      name("100","3","SY","aspi second synonym","TEST_SOURCE")+
      name("101","4","SBD","aspi branded product")+
      name("102","5","IN","aspi ingredient")+
      name("103","6","DF","aspi dose form")+
      name("104","7","SCD","as% literal percent product")+
      name("105","8","SCD","as_ literal underscore product")+
      name("106","9","SCD","very long synthetic product")+
      name("106","10","SY","a"*3500,"TEST_SOURCE"))
    Files.writeString(dir.resolve("RXNREL.RRF"),"")
    dir
  }
  private def cleanup(dir: Path): UIO[Unit] = ZIO.attemptBlocking {
    val files=Files.walk(dir)
    try files.iterator.asScala.toVector.reverse.foreach(Files.deleteIfExists(_)) finally files.close()
  }.orDie.unit
  private def check(condition: Boolean,message: String): Task[Unit] = ZIO.attempt(require(condition,message))

  /** Supports PostgreSQL-compatible test engines without COPY wire support.
    * Production queries still run unchanged; import/COPY are explicitly skipped.
    */
  private def simpleProtocolDriver: Task[Unit] = ZIO.attempt {
    Class.forName("org.postgresql.Driver")
    DriverManager.getDrivers.asScala.filter(_.getClass.getName == "org.postgresql.Driver").toVector.foreach(DriverManager.deregisterDriver)
    val delegate=new org.postgresql.Driver()
    DriverManager.registerDriver(new java.sql.Driver {
      override def connect(url: String,info: java.util.Properties): java.sql.Connection =
        val properties=new java.util.Properties()
        info.stringPropertyNames.asScala.foreach(k => properties.setProperty(k,info.getProperty(k)))
        properties.setProperty("preferQueryMode","simple")
        delegate.connect(url,properties)
      override def acceptsURL(url: String): Boolean = delegate.acceptsURL(url)
      override def getPropertyInfo(url: String,info: java.util.Properties): Array[java.sql.DriverPropertyInfo] = delegate.getPropertyInfo(url,info)
      override def getMajorVersion(): Int = delegate.getMajorVersion()
      override def getMinorVersion(): Int = delegate.getMinorVersion()
      override def jdbcCompliant(): Boolean = delegate.jdbcCompliant()
      override def getParentLogger(): java.util.logging.Logger = java.util.logging.Logger.getLogger("search-read-fixture")
    })
  }

  private def seed(config: PGConfig,prepared: PreparedRrf): Task[Unit] = ZIO.attemptBlocking {
    Using.resource(DriverManager.getConnection(s"jdbc:postgresql://${config.host}:${config.port}/${config.database}",config.user,config.password)) { c =>
      def insert(table: String,columns: String,values: Vector[String]): Unit =
        Using.resource(c.prepareStatement(s"INSERT INTO rxnorm_lab.$table($columns) VALUES (${Vector.fill(values.size)("?").mkString(",")})")) { p =>
          values.zipWithIndex.foreach((value,i) => p.setString(i+1,value))
          p.executeUpdate()
        }
      c.setAutoCommit(false)
      val manifest=(ListMap.from(prepared.sha256.toVector.sorted): Map[String,String]).toJson
      val identity=Hashing.sha256(Vector(Rrf.scope,prepared.release,manifest).toJson)
      insert("release","release,scope,sha256_json,identity,state",Vector(prepared.release,Rrf.scope,manifest,identity,"ready"))
      prepared.concepts.foreach(x => insert("rx_concept","release,rxcui,tty,display",Vector(prepared.release,x.rxcui,x.tty,x.display)))
      prepared.foreachDescription(x => insert("lexical_name","release,rxcui,rxaui,text,normalized,tty,sab",
        Vector(prepared.release,x.rxcui,x.rxaui,x.text,x.normalized,x.tty,x.sab)))
      c.commit()
    }
  }

  def run = ZIO.scoped {
    for
      args <- getArgs
      readOnlyFixture=args.contains("--read-only-fixture")
      _ <- if readOnlyFixture then simpleProtocolDriver else ZIO.unit
      dir <- ZIO.acquireRelease(fixture)(cleanup)
      config <- PGConfig.fromEnvironment
      store <- PostgresStore.open(config)
      prepared <- ZIO.attemptBlocking(Rrf.prepare(dir,release))
      _ <- if readOnlyFixture then seed(config,prepared) else store.importIndex(prepared).unit
      other <- ZIO.attemptBlocking(Rrf.prepare(dir,otherRelease))
      _ <- if readOnlyFixture then seed(config,other) else store.importIndex(other).unit
      results <- store.searchProducts(ProductSearchQuery(release,"aspi",20))
      _ <- check(results.items.map(_.rxcui).toSet == Set("100","101") && !results.hasMore,
        "Prefix aliases were not deduplicated, or non-product terms leaked")
      limited <- store.searchProducts(ProductSearchQuery(release,"aspi",1))
      _ <- check(limited.items.size == 1 && limited.hasMore,"Result limit/hasMore failed")
      percent <- store.searchProducts(ProductSearchQuery(release,"as%",20))
      underscore <- store.searchProducts(ProductSearchQuery(release,"as_",20))
      _ <- check(percent.items.map(_.rxcui) == Vector("104") && underscore.items.map(_.rxcui) == Vector("105"),
        "SQL wildcard characters broadened literal prefix search")
      long <- store.searchProducts(ProductSearchQuery(release,"a"*100,20))
      _ <- check(long.items.map(_.rxcui) == Vector("106"),"Long source labels broke bounded prefix index")
      otherResults <- store.searchProducts(ProductSearchQuery(otherRelease,"aspi",20))
      _ <- check(otherResults.items.forall(_.release == otherRelease) && results.items.forall(_.release == release),
        "Results crossed release boundaries")
      unavailable <- store.searchProducts(ProductSearchQuery("2099-03-03","aspi",20)).either
      _ <- check(unavailable.left.toOption.exists {
        case f: ProductSearchFailure => f.status == 404
        case _ => false
      },"Missing release did not return controlled error")
      source=s"medication LocalAlias: rxcui \"100\" rxnormRelease \"$release\" dose 1mg route PO frequency PRN"
      location=SourceLocation("file:///search-fixture.clinical",Position(0,0,0),Position(0,source.length,source.length),source)
      ast=AstRequest("2","explicit-product-v1",release,DocumentSource(location.uri,source),Vector(
        Mention("m1","LocalAlias","medication",location,Dose(BigDecimal(1),"mg"),"PO","PRN","P1","O1",
          productBinding=Some(ProductBinding("100",release)))))
      snapshot <- store.snapshotForResolution(ast)
      selected=Resolver.resolve(ast,snapshot).resolutions.head
      _ <- check(selected.status == "resolved" && selected.selectedProduct.exists(_.rxcui == "100"),
        "Explicit RxCUI did not load/resolve independently of DSL local alias")
      port <- ProductSearchService.start(0,store.searchProducts)
      response <- ZIO.attemptBlocking {
        val uri=URI.create(s"http://127.0.0.1:$port/products?release=$release&q=ASPI&limit=20")
        HttpClient.newHttpClient().send(HttpRequest.newBuilder(uri).GET().build(),HttpResponse.BodyHandlers.ofString())
      }
      report <- ZIO.fromEither(response.body.fromJson[ProductSearchResponse]).mapError(new IllegalStateException(_))
      _ <- check(response.statusCode == 200 && report.query == "aspi" && report.items.map(_.rxcui).toSet == Set("100","101"),
        "Live HTTP/PostgreSQL round trip failed")
      _ <- Console.printLine("Product search SQL/HTTP integration PASSED: bounded-prefix index, synonyms, deduplication, product types, release isolation, literal wildcards, limits, explicit ID resolution and live HTTP. " +
        (if readOnlyFixture then "SKIPPED: native PostgreSQL COPY/importer; synthetic rows seeded with JDBC." else "Native PostgreSQL COPY/importer also passed."))
    yield ()
  }
