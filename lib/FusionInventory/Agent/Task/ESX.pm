package FusionInventory::Agent::Task::ESX;

use strict;
use warnings;
use parent 'FusionInventory::Agent::Task';

use FusionInventory::Agent::Config;
use FusionInventory::Agent::HTTP::Client::Fusion;
use FusionInventory::Agent::Logger;
use FusionInventory::Agent::Inventory;
use FusionInventory::Agent::XML::Query::Inventory;
use FusionInventory::Agent::SOAP::VMware;

use FusionInventory::Agent::Task::ESX::Version;

our $VERSION = FusionInventory::Agent::Task::ESX::Version::VERSION;

sub isEnabled {
    my ($self) = @_;

    if (!$self->{target}->isa('FusionInventory::Agent::Target::Server')) {
        $self->{logger}->debug("ESX task not compatible with local target");
        return;
    }

    return 1;
}

sub connect {
    my ( $self, %params ) = @_;

    my $url = 'https://' . $params{host} . '/sdk/vimService';

    my $vpbs =
      FusionInventory::Agent::SOAP::VMware->new(url => $url, vcenter => 1 );
    if ( !$vpbs->connect( $params{user}, $params{password} ) ) {
        $self->lastError($vpbs->{lastError});
        return;
    }

    $self->{vpbs} = $vpbs;
}

sub createInventory {
    my ( $self, $id, $tag ) = @_;

    die unless $self->{vpbs};

    my $vpbs = $self->{vpbs};

    my $host = $vpbs->getHostFullInfo($id);

    my $inventory = FusionInventory::Agent::Inventory->new(
        logger => $self->{logger},
        tag    => $tag
    );

    $inventory->setRemote('esx');

    $inventory->setBios( $host->getBiosInfo() );

    $inventory->setHardware( $host->getHardwareInfo() );

    foreach my $cpu ($host->getCPUs()) {
        $inventory->addEntry(section => 'CPUS', entry => $cpu);
    }

    foreach my $controller ($host->getControllers()) {
        $inventory->addEntry(section => 'CONTROLLERS', entry => $controller);

        if ($controller->{PCICLASS} && $controller->{PCICLASS} eq '300') {
            $inventory->addEntry(
                section => 'VIDEOS',
                entry   => {
                    NAME    => $controller->{NAME},
                    PCISLOT => $controller->{PCISLOT},
                }
            );
        }
    }

    my %ipaddr;
    foreach my $network ($host->getNetworks()) {
        $ipaddr{ $network->{IPADDRESS} } = 1 if $network->{IPADDRESS};
        $inventory->addEntry(section => 'NETWORKS', entry => $network);
    }

    $inventory->setHardware( { IPADDR => join '/', ( keys %ipaddr ) } );

    # TODO
    #    foreach (@{$host->[0]{config}{fileSystemVolume}{mountInfo}}) {
    #
    #    }

    foreach my $storage ($host->getStorages()) {
        # TODO
        #        $volumnMapping{$entry->{canonicalName}} = $entry->{deviceName};
        $inventory->addEntry(section => 'STORAGES', entry => $storage);
    }

    foreach my $drive ($host->getDrives()) {
        $inventory->addEntry( section => 'DRIVES', entry => $drive);
    }

    foreach my $machine ($host->getVirtualMachines()) {
        $inventory->addEntry(section => 'VIRTUALMACHINES', entry => $machine);
    }

    return $inventory;

}

sub getHostIds {
    my ($self) = @_;

    return $self->{vpbs}->getHostIds();
}

sub run {
    my ( $self, %params ) = @_;

    $self->{client} = FusionInventory::Agent::HTTP::Client::Fusion->new(
        logger       => $self->{logger},
        user         => $params{user},
        password     => $params{password},
        proxy        => $params{proxy},
        ca_cert_file => $params{ca_cert_file},
        ca_cert_dir  => $params{ca_cert_dir},
        no_ssl_check => $params{no_ssl_check},
        debug        => $self->{debug}
    );
    die unless $self->{client};

    my $globalRemoteConfig = $self->{client}->send(
        "url" => $self->{target}->{url},
        args  => {
            action    => "getConfig",
            machineid => $self->{deviceid},
            task      => { ESX => $VERSION },
        }
    );

    if (!$globalRemoteConfig->{schedule}) {
        $self->{logger}->info("No job schedule returned from server at ".$self->{target}->{url});
        return;
    }
    if (ref( $globalRemoteConfig->{schedule} ) ne 'ARRAY') {
        $self->{logger}->info("Malformed schedule from server at ".$self->{target}->{url});
        return;
    }
    if ( !@{$globalRemoteConfig->{schedule}} ) {
        $self->{logger}->info("No ESX job enabled or ESX support disabled server side.");
        return;
    }

    foreach my $job ( @{ $globalRemoteConfig->{schedule} } ) {
        next unless $job->{task} eq "ESX";
        $self->{esxRemote} = $job->{remote};
    }
    if ( !$self->{esxRemote} ) {
        $self->{logger}->info("No ESX job found in server jobs list.");
        return;
    }

    my $jobs = $self->{client}->send(
        "url" => $self->{esxRemote},
        args  => {
            action    => "getJobs",
            machineid => $self->{deviceid}
        }
    );

    return unless $jobs;
    return unless ref( $jobs->{jobs} ) eq 'ARRAY';
    $self->{logger}->info(
        "Got " . int( @{ $jobs->{jobs} } ) . " VMware host(s) to inventory." );

    my $ocsClient = FusionInventory::Agent::HTTP::Client::OCS->new(
        logger       => $self->{logger},
        user         => $params{user},
        password     => $params{password},
        proxy        => $params{proxy},
        ca_cert_file => $params{ca_cert_file},
        ca_cert_dir  => $params{ca_cert_dir},
        no_ssl_check => $params{no_ssl_check},
        no_compress  => $params{no_compress},
    );

    foreach my $job ( @{ $jobs->{jobs} } ) {

        if ( !$self->connect(
                host     => $job->{host},
                user     => $job->{user},
                password => $job->{password}
        )) {
            $self->{client}->send(
                "url" => $self->{esxRemote},
                args  => {
                    action => 'setLog',
                    machineid => $self->{deviceid},
                    part      => 'login',
                    uuid      => $job->{uuid},
                    msg       => $self->lastError(),
                    code      => 'ko'
                }
            );

            next;
        }

        my $hostIds = $self->getHostIds();
        foreach my $hostId (@$hostIds) {
            my $inventory = $self->createInventory(
                $hostId, $self->{config}->{tag}
            );

            my $message = FusionInventory::Agent::XML::Query::Inventory->new(
                deviceid => $self->{deviceid},
                content  => $inventory->getContent()
            );

            $ocsClient->send(
                url     => $self->{target}->getUrl(),
                message => $message
            );
        }
        $self->{client}->send(
            "url" => $self->{esxRemote},
            args  => {
                action => 'setLog',
                machineid => $self->{deviceid},
                uuid      => $job->{uuid},
                code      => 'ok'
            }
        );

    }

    return $self;
}

sub lastError {
    my ($self, $error) = @_;

    $self->{lastError} = $error if $error;

    return $self->{lastError} || "n/a";
}

1;

__END__

=head1 NAME

FusionInventory::Agent::SOAP::VMware - Access to VMware hypervisor

=head1 DESCRIPTION

This module allow access to VMware hypervisor using VMware SOAP API
and _WITHOUT_ their Perl library.

=head1 FUNCTIONS

=head2 connect ( $self, %params )

Connect the task to the VMware ESX, ESXi or vCenter.

=head2 createInventory ( $self, $id, $tag )

Returns an FusionInventory::Agent::Inventory object for a given
host id.

=head2 getHostIds

Returns the list of the host id.
