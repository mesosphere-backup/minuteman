node('mesos') {
    stage 'build'
    checkout scm
    def myImage = docker.build "erlang19.1"
    
    myImage.inside {
        checkout scm
        sh 'ip link add webserver type dummy'
        sh 'ip link set webserver up'
        sh 'ip addr add 1.1.1.1/32 dev webserver'
        sh 'ip addr add 1.1.1.2/32 dev webserver'
        sh 'ip addr add 1.1.1.3/32 dev webserver'
        sh 'mkdir /tmp/htdocs'
        sh 'modprobe ip_vs_wlc'
        sh 'make'
        sh 'make check'
        sh './elvis rock'
    }
}
