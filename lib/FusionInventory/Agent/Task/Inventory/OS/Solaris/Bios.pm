package FusionInventory::Agent::Task::Inventory::OS::Solaris::Bios;

use strict;
use warnings;

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Solaris;

sub isEnabled {
    return
        can_run('showrev') ||
        can_run('/usr/sbin/smbios');
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};

    my ($SystemSerial, $SystemModel, $SystemManufacturer, $BiosManufacturer,
        $BiosVersion, $BiosDate, $uuid);
    my $aarch =
        getFirstLine(command => 'arch') eq 'i86pc' ? 'i386' : 'unknown';

    my $zone = getZone();
    if ($zone) {
        if (can_run('showrev')) {
            my $handle = getFileHandle(
                command => "showrev",
            );
            while (my $line = <$handle>) {
                if ($line =~ /^Application architecture:\s+(\S+)/) { 
                    $SystemModel = $1
                };
                if ($line =~ /^Hardware provider:\s+(\S+)/) {
                    $SystemManufacturer = $1
                };
                if ($line =~ /^Application architecture:\s+(\S+)/) {
                    $aarch = $1
                };
            }
            close $handle;
        }
        if ($aarch eq "i386"){
            #
            # For a Intel/AMD arch, we're using smbio
            #
            my $handle = getFileHandle(
                command => "/usr/sbin/smbios"
            );
            while (my $line = <$handle>) {
                if ($line =~ /^\s*Manufacturer:\s*(.+)$/) {
                    $SystemManufacturer = $1
                }
                if ($line =~ /^\s*Serial Number:\s*(.+)$/) {
                    $SystemSerial = $1;
                }
                if ($line =~ /^\s*Product:\s*(.+)$/) {
                    $SystemModel = $1;
                }
                if ($line =~ /^\s*Vendor:\s*(.+)$/) {
                    $BiosManufacturer = $1;
                }
                if ($line =~ /^\s*Version String:\s*(.+)$/) {
                    $BiosVersion = $1;
                }
                if ($line =~ /^\s*Release Date:\s*(.+)$/) {
                    $BiosDate = $1;
                }
                if ($line =~ /^\s*UUID:\s*(.+)$/) {
                    $uuid = $1;
                }
            }
            close $handle;
        } elsif ($aarch =~ /sparc/i) {
            #
            # For a Sparc arch, we're using prtconf
            #

            my $handle = getFileHandle(
                command => "/usr/sbin/prtconf -pv"
            );

            my ($name, $OBPstring);
            while (my $line = <$handle>) {
                # prtconf is an awful thing to parse
                if ($line =~ /^\s*banner-name:\s*'(.+)'$/) {
                    $SystemModel = $1;
                }
                unless ($name) {
                    if ($line =~ /^\s*name:\s*'(.+)'$/) {
                        $name = $1;
                    }
                }
                unless ($OBPstring) {
                    if ($line =~ /^\s*version:\s*'(.+)'$/) {
                        $OBPstring = $1;
                        # looks like : "OBP 4.16.4 2004/12/18 05:18"
                        #    with further informations sometime
                        if ($OBPstring =~ m@OBP\s+([\d|\.]+)\s+(\d+)/(\d+)/(\d+)@ ) {
                            $BiosVersion = "OBP $1";
                            $BiosDate = "$2/$3/$4";
                        } else {
                            $BiosVersion = $OBPstring;
                        }
                    }
                }
            }
            close $handle;

            $SystemModel .= " ($name)" if( $name );

            if( -x "/opt/SUNWsneep/bin/sneep" ) {
                $SystemSerial = getFirstLine(
                    command => '/opt/SUNWsneep/bin/sneep'
                );
            } else {
                foreach(`/bin/find /opt -name sneep`) {
                    next unless /^(\S+)/;
                    $SystemSerial = getFirstLine(command => $1);
                }
            }
        }
    } else {
        my $handle = getFileHandle(
            command => "showrev",
        );
        while (my $line = <$handle>) {
            if ($line =~ /^Hardware provider:\s+(\S+)/) {
                $SystemManufacturer = $1
            };
        }
        close $handle;

        $SystemModel = "Solaris Containers";
        $SystemSerial = "Solaris Containers";

    }

    $inventory->setBios({
        BVERSION      => $BiosVersion,
        BDATE         => $BiosDate,
        SMANUFACTURER => $SystemManufacturer,
        SMODEL        => $SystemModel,
        SSN           => $SystemSerial
    });

    $inventory->setHardware({
        UUID => $uuid
    });
}

1;
