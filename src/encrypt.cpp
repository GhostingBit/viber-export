// Encrypt a plaintext SQLite DB into a Viber-codec-encrypted DB (schema-preserving).
// usage: encrypt <plaintext.db> <hexkey-or-scheme:key> <out-encrypted.db>
#include <QCoreApplication>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QSqlError>
#include <QVariant>
#include <QStringList>
#include <QFile>
#include <cstdio>
static bool run(QSqlQuery&q,const QString&s){ if(!q.exec(s)){ printf("ERR [%s]: %s\n", s.left(60).toUtf8().constData(), q.lastError().text().toUtf8().constData()); return false;} return true; }
int main(int argc,char**argv){
  QCoreApplication app(argc,argv);
  if(argc<4){ printf("usage: encrypt <plain.db> <key> <out.db>\n"); return 2; }
  QString in=argv[1], key=argv[2], out=argv[3];
  QFile::remove(out); QFile::remove(out+"-wal"); QFile::remove(out+"-shm"); QFile::remove(out+"-journal");
  int rc=1;
  {
    QSqlDatabase db=QSqlDatabase::addDatabase("QSQLITE","e");
    db.setDatabaseName(out);
    if(!db.open()){ printf("open fail: %s\n", db.lastError().text().toUtf8().constData()); }
    else {
      QSqlQuery q(db);
      q.exec("PRAGMA hexkey='"+key+"'");
      run(q,"PRAGMA journal_mode=DELETE");
      if(!run(q,"ATTACH DATABASE '"+in+"' AS p KEY ''")) { db.close(); QSqlDatabase::removeDatabase("e"); return 1; }
      // recreate schema (tables first, then index/trigger), skipping internal
      QSqlQuery s(db);
      QStringList tbls, others;
      s.exec("SELECT type,name,sql FROM p.sqlite_master WHERE sql NOT NULL AND name NOT LIKE 'sqlite_%'");
      QList<QStringList> rows;
      while(s.next()) rows << (QStringList()<<s.value(0).toString()<<s.value(1).toString()<<s.value(2).toString());
      for(const auto&r:rows) if(r[0]=="table") run(q,r[2]);
      // copy data
      int okc=0,tot=0;
      for(const auto&r:rows) if(r[0]=="table"){ tot++; QSqlQuery c(db); if(c.exec(QString("INSERT INTO main.\"%1\" SELECT * FROM p.\"%1\"").arg(r[1]))) okc++; else printf("  data %s: %s\n", r[1].toUtf8().constData(), c.lastError().text().toUtf8().constData()); }
      for(const auto&r:rows) if(r[0]!="table") run(q, r[2]);   // indexes, triggers
      run(q,"DETACH DATABASE p");
      printf("ENCRYPTED: %d/%d tables into %s\n", okc, tot, out.toUtf8().constData());
      rc=0; db.close();
    }
  }
  QSqlDatabase::removeDatabase("e");
  return rc;
}
