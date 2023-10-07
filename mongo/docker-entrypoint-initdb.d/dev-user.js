db = connect( 'mongodb://localhost/admin' );

db.createUser(
  {
    user: "dev",
    pwd:  "dev-admin",
    roles: [ "dbAdmin" ]
  }
)

db = connect( 'mongodb://localhost/confector' );
db.createUser(
  {
    user: "dev-read-write",
    pwd:  "dev-read-write",
    roles: [ { role: "readWrite", db: "confector" } ]
  }
)
