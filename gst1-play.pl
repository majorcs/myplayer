#!/usr/bin/perl
use warnings;
use strict;
use Glib;
use Glib::Object::Introspection;
use Data::Dumper;

Glib::Object::Introspection->setup(basename => 'Gst', version => '1.0', package => 'GStreamer1');
GStreamer1::init_check([ $0, @ARGV ]) or die "Can't initialize gstreamer-1.x\n";
my $reg= GStreamer1::Registry::get();
$reg->lookup_feature('playbin') or die "gstreamer-1.x plugin 'playbin' not found.\n";

my $playbin= GStreamer1::ElementFactory::make('playbin' => 'playbin');
my $bus=$playbin->get_bus;
$bus->add_signal_watch;

$bus->signal_connect('message::eos' => \&bus_message_end,0);
$bus->signal_connect('message::error' => \&bus_message_end,1);
$bus->signal_connect('message::state-changed' => \&state_changed);

my $sinkname="pulse";
my $sink=GStreamer1::ElementFactory::make($sinkname.'sink' => $sinkname);
die "can't creat sink $sinkname\n" unless $sink;
#$sink->set($option => $value);

$playbin->set('audio-sink' => $sink);

my $mainloop=Glib::MainLoop->new;

Glib::Timeout->add(500,\&UpdateTime);
my @ToPlay= @ARGV;
PlayNext();

$mainloop->run;



sub PlayNext
{	my $file=shift @ToPlay;
	exit 0 unless $file;
	if ($file!~m#^([a-z]+)://#)
	{	$file=~s#([^A-Za-z0-9-/\.])#sprintf('%%%02X', ord($1))#seg;
		$file='file://'.$file;
	}
	$playbin->set(uri => $file);
	warn "playing $file\n";
	$playbin->set_state('playing');
}

sub UpdateTime
{	my $self=shift;
	my ($result,$state,$pending)= $playbin->get_state(0);
	warn "state: $result,$state,$pending\n" if 0;
	return 1 if $result eq 'async';
	if ($state ne 'playing' && $state ne 'paused')
	{	return 1 if $pending eq 'playing' || $pending eq 'paused';
		return 0;
	}
	my $query=GStreamer1::Query->new_duration('time');
	if ($playbin->query($query))
	{
	 	my (undef, $duration)=$query->parse_duration;
		$duration/=1_000_000_000;
		print("DUR: $duration\n");
	}
	my $query=GStreamer1::Query->new_position('time');
	if ($playbin->query($query))
	{	my (undef, $position)=$query->parse_position;
		$position/=1_000_000_000;
		printf STDERR "%s %02d:%02d\n",$state, $position/60,$position%60;
	}
	return 1;
}

sub bus_message_end
{	my ($msg,$error)=($_[1],$_[2]);
	$playbin->set_state('null');
	#error msg if $error is true, else eos
	if ($error)	{ warn $_ for _parse_error($msg); exit 1 }
	else		{ PlayNext(); }
}

sub _parse_error
{	my $msg=shift;
	my $s=$msg->get_structure;
	return $s->get_value('gerror')->message, $s->get_string('debug');
}

sub state_changed
{
	my ($bus, $msg) = @_;
	print("MSG: ".$msg->type."\n");
	print $playbin->get_state(0)."\n";
}
