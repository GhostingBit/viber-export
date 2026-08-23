// dump.cpp — decrypt a Viber-encrypted SQLite DB to a plaintext copy, using Viber's OWN
// codec plugin (libqsqlite). Data-faithful export (all tables + rows). Browsable in any
// SQLite tool. See INTERNALS.md for how the codec/keys work.
//
// usage: dump <encrypted-viber.db> <hexkey-value> <output-plaintext.db>
#include <QCoreApplication>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QSqlError>
#include <QVariant>
#include <QStringList>
#include <QFile>
#include <cstdio>
int main(int argc, char** argv){
  QCoreApplication app(argc, argv);
  if (argc < 4){ fprintf(stderr,"usage: dump <viber.db> <hexkey> <out.db>\n"); return 2; }
  QString src=argv[1], key=argv[2], out=argv[3];
  QFile::remove(out); QFile::remove(out+"-wal"); QFile::remove(out+"-shm"); QFile::remove(out+"-journal");
  int rc=1;
  {
    QSqlDatabase db=QSqlDatabase::addDatabase("QSQLITE","enc");
    db.setDatabaseName(src);
    if(!db.open()){ fprintf(stderr,"OPEN_FAIL %s\n", db.lastError().text().toUtf8().constData()); }
    else {
      QSqlQuery q(db);
      q.exec("PRAGMA hexkey='"+key+"'");
      if(!q.exec("SELECT count(*) FROM sqlite_master") || !q.next()){
        fprintf(stderr,"DECRYPT_FAIL %s\n", q.lastError().text().toUtf8().constData());
      } else {
        QStringList tables; QSqlQuery t(db);
        t.exec("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
        while(t.next()) tables<<t.value(0).toString();
        QSqlQuery a(db);
        if(!a.exec("ATTACH DATABASE '"+out+"' AS pln KEY ''")){
          fprintf(stderr,"ATTACH_FAIL %s\n", a.lastError().text().toUtf8().constData());
        } else {
          int okc=0;
          for(const QString& tb: tables){ QSqlQuery c(db);
            if(c.exec(QString("CREATE TABLE pln.\"%1\" AS SELECT * FROM main.\"%1\"").arg(tb))) okc++;
            else fprintf(stderr,"  skip %s: %s\n", tb.toUtf8().constData(), c.lastError().text().toUtf8().constData());
          }
          QSqlQuery d(db); d.exec("DETACH DATABASE pln");
          printf("OK: exported %d/%d tables -> %s\n", okc, tables.size(), out.toUtf8().constData());
          rc=0;
        }
      }
      db.close();
    }
  }
  QSqlDatabase::removeDatabase("enc");
  return rc;
}
