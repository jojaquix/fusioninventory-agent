package FusionInventory::Agent::Target;

use strict;
use warnings;

use Config;
use English qw(-no_match_vars);

use FusionInventory::Agent::Storage;
use FusionInventory::Agent::AccountInfo;

BEGIN {
    # threads and threads::shared must be loaded before
    # $lock is initialized
    if ($Config{usethreads}) {
        eval {
            require threads;
            require threads::shared;
        };
        if ($EVAL_ERROR) {
            print "[error]Failed to use threads!\n"; 
        }
    }
}

# resetNextRunDate() can also be called from another thread (RPC)
my $lock : shared;

sub new {
    my ($class, $params) = @_;

    my $self = {
        config          => $params->{config},
        type            => $params->{type},
        logger          => $params->{logger},
        path            => $params->{path} || '',
        deviceid        => $params->{deviceid},
        debugPrintTimer => 0
    };
    bless $self, $class;

    my $config = $self->{config};
    my $logger = $self->{logger};

    lock($lock);

    my $nextRunDate : shared;
    $self->{nextRunDate} = \$nextRunDate;

    $self->{format} = $params->{type} eq 'local' && $config->{html} ?
        'HTML' : 'XML';
   
    $self->init();

    if ($params->{type} !~ /^(server|local|stdout)$/ ) {
        $logger->fault('bad type'); 
    }

    # restore previous state
    $self->{storage} = FusionInventory::Agent::Storage->new({
        logger    => $self->{logger},
        directory => $self->{vardir}
    });
    my $storage = $self->{storage};
    $self->{myData} = $storage->restore();


    if ($self->{myData}{nextRunDate}) {
        $logger->debug (
            "[$self->{path}] Next server contact planned for ".
            localtime($self->{myData}{nextRunDate})
        );
        ${$self->{nextRunDate}} = $self->{myData}{nextRunDate};
    }

    $self->{accountinfo} = FusionInventory::Agent::AccountInfo->new({
            logger => $logger,
            config => $config,
            target => $self,
        });

    my $accountinfo = $self->{accountinfo};

    if ($config->{tag}) {
        if ($accountinfo->get("TAG")) {
            $logger->debug(
                "A TAG seems to already exist in the server for this ".
                "machine. The -t paramter may be ignored by the server " .
                "unless it has OCS_OPT_ACCEPT_TAG_UPDATE_FROM_CLIENT=1."
            );
        }
        $accountinfo->set("TAG", $config->{tag});
    }
    $self->{currentDeviceid} = $self->{myData}{currentDeviceid};

    return $self;
}

# TODO refactoring needed here.
sub init {
    my ($self) = @_;

    my $config = $self->{config};
    my $logger = $self->{logger};

    lock($lock);

    if ($self->{type} eq 'server') {
        my $dir = $self->{path};
        $dir =~ s/\//_/g;
        # On Windows, we can't have ':' in directory path
        $dir =~ s/:/../g if $OSNAME eq 'MSWin32';
        $self->{vardir} = $config->{basevardir} . "/" . $dir;
    } else {
        $self->{vardir} = $config->{basevardir} . "/__LOCAL__";
    }
    $logger->debug("vardir: $self->{vardir}");

    $self->{accountinfofile} = $self->{vardir} . "/ocsinv.adm";
    $self->{last_statefile} = $self->{vardir} . "/last_state";
}

sub setNextRunDate {

    my ($self, $args) = @_;

    my $config = $self->{config};
    my $logger = $self->{logger};
    my $storage = $self->{storage};

    lock($lock);

    my $serverdelay = $self->{myData}{prologFreq};

    lock($lock);

    my $max;
    if ($serverdelay) {
        $max = $serverdelay * 3600;
    } else {
        $max = $config->{delaytime};
        # If the PROLOG_FREQ has never been initialized, we force it at 1h
        $self->setPrologFreq(1);
    }
    $max = 1 unless $max;

    my $time = time + ($max/2) + int rand($max/2);

    $self->{myData}{nextRunDate} = $time;
    
    ${$self->{nextRunDate}} = $self->{myData}{nextRunDate};

    $logger->debug (
        "[$self->{path}] Next server contact has just been planned for ".
        localtime($self->{myData}{nextRunDate})
    );

    $storage->save({ data => $self->{myData} });
}

sub getNextRunDate {
    my ($self) = @_;

    my $config = $self->{config};
    my $logger = $self->{logger};

    lock($lock);

    if (${$self->{nextRunDate}}) {
        if ($self->{debugPrintTimer} < time) {
            $self->{debugPrintTimer} = time + 600;
        }; 

        return ${$self->{nextRunDate}};
    }

    $self->setNextRunDate();

    if (!${$self->{nextRunDate}}) {
        $logger->fault('nextRunDate not set!');
    }

    return $self->{myData}{nextRunDate} ;

}

sub resetNextRunDate {
    my ($self) = @_;

    my $logger = $self->{logger};
    my $storage = $self->{storage};

    lock($lock);
    $logger->debug("Force run now");
    
    $self->{myData}{nextRunDate} = 1;
    $storage->save({ data => $self->{myData} });
    
    ${$self->{nextRunDate}} = $self->{myData}{nextRunDate};
}

sub setPrologFreq {

    my ($self, $prologFreq) = @_;

    my $config = $self->{config};
    my $logger = $self->{logger};
    my $storage = $self->{storage};

    return unless $prologFreq;

    if ($self->{myData}{prologFreq} && ($self->{myData}{prologFreq}
            eq $prologFreq)) {
        return;
    }
    if (defined($self->{myData}{prologFreq})) {
        $logger->info(
            "PROLOG_FREQ has changed since last process ". 
            "(old=$self->{myData}{prologFreq},new=$prologFreq)"
        );
    } else {
        $logger->info("PROLOG_FREQ has been set: $prologFreq");
    }

    $self->{myData}{prologFreq} = $prologFreq;
    $storage->save({ data => $self->{myData} });

}

sub setCurrentDeviceID {

    my ($self, $deviceid) = @_;

    my $config = $self->{config};
    my $logger = $self->{logger};
    my $storage = $self->{storage};

    return unless $deviceid;

    if ($self->{myData}{currentDeviceid} &&
        ($self->{myData}{currentDeviceid} eq $deviceid)) {
        return;
    }

    if (!$self->{myData}{currentDeviceid}) {
        $logger->debug("DEVICEID initialized at $deviceid");
    } else {
        $logger->info(
            "DEVICEID has changed since last process ". 
            "(old=$self->{myData}{currentDeviceid},new=$deviceid"
        );
    }

    $self->{myData}{currentDeviceid} = $deviceid;
    $storage->save({ data => $self->{myData} });

    $self->{currentDeviceid} = $deviceid;

}

1;
