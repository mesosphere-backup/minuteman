# Minuteman
[![Circle CI](https://circleci.com/gh/dcos/minuteman.svg?style=svg&circle-token=571c4d23069b744377653d0f1246296c784bd9b0)](https://circleci.com/gh/dcos/minuteman)
[![velocity](http://velocity.mesosphere.com/service/velocity/buildStatus/icon?job=public-dcos-networking-minuteman-master)](http://velocity.mesosphere.com/service/velocity/job/public-dcos-networking-minuteman-master/)
[![codecov.io](http://codecov.io/github/dcos/minuteman/coverage.svg)](http://codecov.io/github/dcos/minuteman)

A distributed, highly available service discovery & internal load balancer for distributed systems (microservices and containers).

* [Slides](https://docs.google.com/presentation/d/1KkyQL_kibE3O6OovvGT_06W-4c3BSxDpDZo5w3kB7Bk)

## Powers:
* VIPs: https://dcos.io/docs/1.7/overview/service-discovery/
* [DC/OS](http://dcos.io)


## Usage
You can use the layer 4 load balancer by specifying a VIP from the Marathon UI. The VIP must be specified in the format IP:port, for example: *10.1.2.3:5000*. Alternatively, if you're using something other than Marathon, you can create a label on the [port](https://github.com/apache/mesos/blob/b18f5bf48fda12bce9c2ac8e762a08f537ffb41d/include/mesos/mesos.proto#L1813) protocol buffer while launching a task on Mesos. This label's key must be in the format `VIP_$IDX`, where `$IDX` is replaced by a number, starting from 0. Once you create a task, or a set of tasks with a VIP, they will automatically become available to all nodes in the cluster, including the masters.

### Details
When you launch a set of tasks with these labels, we distribute them to all of the nodes in the cluster. All of the nodes in the cluster act as decision makers in the load balancing process. There is a process that runs on all the agents which is consulted by the kernel when packets are recognized with this destination address. This process keeps track of availability and reachability of these tasks to attempt to send requests to the right backends

### Recommendations

#### Caveats
1. You musn't firewall traffic between the nodes
2. You musn't change `ip_local_port_range`
3. You must have the `ipset` package installed
4. You must run a stock kernel from RHEL 7.2+, or Ubuntu 14.04+ LTS

#### Persistent Connections
It is recommended when you use our VIPs you keep long-running, persistent connections. The reason behind this is that you can very quickly fill up the TCP socket table if you do not. The default local port range on Linux allows source connections from 32768 to 61000. This allows 28232 connections to be established between a given source IP and a destinaton address, port pair. TCP connections must go through the time wait state prior to being reclaimed. The Linux kernel's default TCP time wait period is 120 seconds. Given this, you would exhaust the connection table by only making 235 new connections / sec.

#### Healthchecks
We also recommend taking advantage of Mesos healthchecks. Mesos healthchecks are surfaced to the load balancing layer. **Marathon** only converts **command** healthchecks to Mesos healthchecks. You can simulate HTTP healthchecks via a command similar to `test "$(curl -4 -w '%{http_code}' -s http://localhost:${PORT0}/|cut -f1 -d" ")" == 200`. This ensures the HTTP status code returned is 200. It also assumes your application binds to localhost. The ${PORT0} is set as a variable by Marathon. We do not recommend using TCP healthchecks as they can be misleading as to the liveness of a service.

### Demo
If you would like to run a demo, you can configure a Marathon app as mentioned above, and use the URI `https://s3.amazonaws.com/sargun-mesosphere/linux-amd64`, as well as the command `chmod 755 linux-amd64 && ./linux-amd64 -listener=:${PORT0} -say-string=version1` to execute it. You can then test it by hitting the application with the command: `curl http://10.1.2.3:5000`. This app exposes an HTTP API. This HTTP API answers with the PID, hostname, and the 'say-string' that's specified in the app definition. In addition, it exposes a long-running endpoint at `http://10.1.2.3:5000/stream`, which will continue to stream until the connection is terminated. The code for the application is available here: `https://github.com/mesosphere/helloworld`.

#### Exposing it to the outside
Prior to this, you had to run a complex proxy that would reconfigure based on the tasks running on the cluster. Fortunately, you no longer need to do this. Instead, you can have an incredible simple HAProxy configuration like so:

```
defaults
  log global
  mode  tcp
  contimeout 50000000
  clitimeout 50000000
  srvtimeout 50000000

listen appname 0.0.0.0:80
    mode tcp
    balance roundrobin
    server mybackend 10.1.2.3:5000
```

A Marathon app definition for this looks like:

```
{
    "acceptedResourceRoles": [
        "slave_public"
    ],
    "container": {
        "docker": {
            "image": "sargun/haproxy-demo:3",
            "network": "HOST"
        },
        "type": "DOCKER"
    },
    "cpus": 0.5,
    "env": {
        "CONFIGURL": "https://gist.githubusercontent.com/sargun/3037bdf8be077175e22c/raw/be172c88f4270d9dfe409114a3621a28d01294c3/gistfile1.txt"
    },
    "instances": 1,
    "mem": 128,
    "ports": [
        80
    ],
    "requirePorts": true
}
```

This will run an HAProxy on the public slave, on port 80. If you'd like, you can make the number of instances equal to the number of public agents. Then, you can point your external load balancer at the pool of public agents on port 80. Adapting this would simply involve changing the backend entry, as well as the external port.

## Potential Roadblocks
### IP Overlay
If the VIP address that's specified is used elsewhere in the network is can prove problematic. Although the VIP is a 3-tuple, it is best to ensure that the IP dedicated to the VIP is only in use by the load balancing software and isn't in use at all in your network. Therefore, you should choose IPs from the RFC1918 range.

### IPSet
You must have the command ipset installed. If you do not, you may see an error like:

```
15:15:59.731 [error] Unknown response: {ok,"iptables v1.4.21: Set minuteman doesn't exist.\n\nTry `iptables -h' or 'iptables --help' for more information.\n"}
```
### Ports
The port 61420 must be open for the load balancer to work correctly. Because the load balancer maintains a partial mesh, it needs to ensure that connectivity between nodes is unhindered.

### Connection table exhaustion
If you begin to see the behaviour as described earlier where the connection table is being exhausted, you'll see various errors in the logs. You can set two sysctls to alleviate this issue, but it doesn't come without caveats.

1. `net.netfilter.nf_conntrack_tcp_timeout_time_wait=0` -- You can set this to 0, but the time_wait state may break connection tracking for other applications
1. `net.ipv4.tcp_tw_reuse=1` -- This sysctl can be dangerous and break firewalls, as well as NAT implementations. Although, if the firewall properly implements tracking TCP timestamps, it'll be okay. *Do not* set the `net.ipv4.tcp_tw_recycle` sysctl as it is RFC non-compliant and will break firewall connection tracking.

More information about these sysctls can be found here: `https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt`.

## Implementation
The local process polls the master node roughly every 5 seconds. The master node caches this for 5 seconds as well, bounding the propagation time for an update to roughly 11 seconds. Although this is the case for new VIPs, it is not the case for failed nodes.

### Data plane
The load balancer dataplane primarily utilizes Netfilter. The load balancer installs 4 IPTables rules to enable this, therefore the load balancer must start after firewalld, or any other destructive IPTables management system. These 4 rules tell IPTables to put the packets that match them on an NFQueue. NFQueue is a kernel subsystem that allows userspace to process network traffic.

The rules are two types - the first type is to intercept the traffic, and the second is to drop it. The purpose of the latter rule is to provide an immediate connection reset to the client. The prior set of rules matches based on the combination of a TCP packet, the SYN flag (and none else), and an IPSet match which is populated with the list of VIPs.

Once the packet is on the nfqueue, we calculate the backend that the connection should be mapped to. We use this information to program in an in-kernel conntrack entry which maps (port DNATs) the 5-tuple from the original destination (the VIP) to the new destination (the backend). In some cases where hairpin load balancing occurs, SNAT may be required as well.

Once the NAT programming is done, the packet is released back into the kernel. Since our rules are in the raw chain the packet doesn't yet have a conntrack entry associated with it. The conntrack subsystem recognizes the connection based on the prior program and continues to handle the rest of the flow independently from the load balancer.

### Load balancing algorithm
The load balancing algorithm is adapted from *The Power of Two Choices in Randomized Load Balancing* (IEEE Trans. Parallel Distrib. Syst. 12, Michael Mitzenmacher). We switch between this algorithm in the raw sense, and a more probabilistic algorithm depending on whether or not more than 10 backends exist for a given VIP. The simple vs. probabilistic algorithm utilization is exposed in the metrics information.

The simple algorithm maintains an EWMA of latencies for a given backend at connection time. It also maintains a set of consecutive failures, and when they happened. If a backend observes enough consecutive failures in a short period of time (<5m) it is considered to be unavailable. A failure is classified as three way handshake failing to occur.

The primary way the algorithm works is that it iterates over the backends and finds those that we assume are available after taking the the historical failures as well as the group failure detector. It then takes two random nodes from the most available bucket.

The probabilistic failure detector randomly chooses backends and checks whether or not the group failure detector considers the agent to be alive. It will continue to do this until it either finds 2 backends that are in the ideal bucket, or until 20 lookups happen. If the prior case happens, it'll choose one at random. If the latter case happens it'll choose one of the 20 at random.

### Failure detection
The load balancer includes a state of the art failure detection scheme. This failure detection scheme takes some of the work done in the [Hyparview](http://asc.di.fct.unl.pt/~jleitao/pdf/dsn07-leitao.pdf) work. The failure detector maintains a fully connected sparse graph of connections amongst the nodes in the cluster.

Every node maintains an adjacency table. These adjacency tables are gossiped to every other node in the cluster. These adjacency tables are then used to build an application-level multicast overlay.

These connections are monitored via an adaptive ping algorithm. The adaptive ping algorithm maintains a window of pings between neighbors, and if the ping times out, they sever the connections. Once this connection is severed the new adjacencies are gossiped to all other nodes, therefore potentially triggering cascading healthchecks. This allows the system to detect failures in less than a second. Although, the system has backpressure when there are lots of failures, and fault detection can rise to 30 seconds.

#### Evaluation
We evaluated the fault-detection of Minuteman in a real world situation. We created a cluster with 40 physical Minuteman / Lashup nodes, and 1000 tasks in one VIP. The testing node created a new connection for every request, and ran 10 threads, each capped at 10 requests a second. 

At 5 seconds into both tests, we failed 12.5% of the machines by artificially introducing a kernel panic. Our purpose of the test was to try to measure the latency deviation, and the time to repair.
##### Active Failure Detection - Pre-Lashup
Active Failure Detection
![Pre-Lashup Graph](http://i.imgur.com/V4dG2nQ.png) 
##### Passive Failure Detection - Post-Lashup
![Post-Lashup Imgur](http://i.imgur.com/KrRho2T.png)
[Basho Bench Config](https://gist.github.com/sargun/47b21249a4e9153bd3a0312d201dac1e)
