# add the datastax cassandra repos
echo deb http://debian.datastax.com/community stable main > /etc/apt/sources.list.d/cassandra.sources.list
wget -qO- -L https://debian.datastax.com/debian/repo_key | sudo apt-key add -

service cassandra start

echo "Waiting for Cassandra service to be available on port 9160"

while ! nc -vz localhost 9160; do
	sleep 1
done

python <<END
import pycassa
sys = pycassa.SystemManager("localhost:9160")

if "reddit" not in sys.list_keyspaces():
    print "creating keyspace 'reddit'"
    sys.create_keyspace("reddit", "SimpleStrategy", {"replication_factor": "1"})
    print "done"

if "permacache" not in sys.get_keyspace_column_families("reddit"):
    print "creating column family 'permacache'"
    sys.create_column_family("reddit", "permacache")
    print "done"
END
