#!/usr/bin/perl

# apt-get install libmp3-tag-perl libconfig-simple-perl libcolor-calc-perl libgtk2-sourceview2-perl libgstreamer-perl libdbd-sqlite3-perl

use Data::Dumper;
use Term::ANSIColor;
use MP3::Tag;
use Time::HiRes qw ( time alarm sleep );
use FindBin;
use File::Basename;
use Config::Simple;
use List::Util qw(min max);
use Color::Calc;
use DBI;
use POSIX;                  

use Glib qw/TRUE FALSE/;
use Gtk2 '-init';
use Gtk2::SimpleList;
use Gtk2::SourceView2;

use GStreamer '-init';

use strict;
use utf8;
use locale;
binmode STDOUT, ":utf8";

#open(DBG, ">/var/tmp/karaokedebug.txt");
#binmode DBG, ":utf8";

setlocale(LC_COLLATE, 'hu_HU.UTF-8');

my $conf_file = "$ENV{HOME}/.mkp.conf";

if (-z $conf_file || ! -f $conf_file)
{
    my $cfg = new Config::Simple(syntax=>'ini');
    $cfg->param('__', time());
    $cfg->save($conf_file);
    $cfg = undef;
}

my $dbh = DBI->connect("dbi:SQLite:dbname=$ENV{HOME}/.myplayer.db","","");
my $sth = $dbh->table_info(undef, undef, 'PLAYINFO');
my $ret = $sth->fetchall_arrayref({});
my $finfo;
if (!scalar(@$ret))
{
    $sth = $dbh->do("create table PLAYINFO (fname varchar(512) primary key not null, lastplay int);");
}
else
{
    $finfo = $dbh->selectall_hashref("select fname, lastplay from PLAYINFO;", ['fname']);
    
    # print(Dumper($finfo));
}

my %Config;
tie %Config, "Config::Simple", $conf_file;
tied(%Config)->autosave(1);

$|=1;
my $song_dir = $Config{'Directories.Song'} || '/home/major/Music/Karaoke';
my $lyrics_dir = $Config{'Directories.Lyrics'} || '/home/major/Documents/lyrics';
my $period = $Config{'System.Period'} || 100; # millisec
my $period = max(50, min(500, $period));
my $curr_time = 0;
my $last_width = 0;
my $last_height = 0;
my @lines;
my $time_offset = 0;
my $last_line = -1;
my $should_play = 0;
my $playing = -1;
my $capturing = 0;
my $capture_time = 0;
my $frame = 0;
my $dirty = 0;
my $last_frame = '';
my $player_pos = 0;
my $player_state = '';
my $player_dur = 0;
my $lyrics_fname = '';
my %lyrics_options;

my $dbglevel = 2;

my @rnd;

my $glade_file = "$FindBin::Bin/myplayer.glade";

my $builder = Gtk2::Builder->new();
my $i = $builder->add_from_file ($glade_file);
$builder->connect_signals();

my $vbEditor = $builder->get_object('vbEditor');
my $lyrics_progress = $builder->get_object('hpProgress');

my $sb = Gtk2::SourceView2::Buffer->new(undef);
# $sb->set_highlight(0);
my $view = Gtk2::SourceView2::View->new_with_buffer($sb);
$view->show;
$view->set_show_line_numbers(1);
$vbEditor->add($view);


my $dlgStart = $builder->get_object('dlgStart');
$dlgStart->show();
my $progress = $builder->get_object('pbLoading');

opendir(SONG, $song_dir);
my @files = grep { /mp3$/i } readdir(SONG);
closedir(SONG);
my $cnt = 0;
my @songs = sort { $a->[0] cmp $b->[0] }
                map 
                { 
                      push(@rnd, $cnt);
                      my $mp3=MP3::Tag->new("$song_dir/$_"); 
                      my @info=$mp3->autoinfo; 
                      $progress->set_text("$cnt/$#files");
                      $progress->set_fraction($cnt++/$#files);
                      Gtk2->main_iteration;
                      
                      utf8::decode($_); 
                      my $diff = time() - $finfo->{$_}->{lastplay};
                      my $lasttime = get_diff_time($diff);
#                      print("Song: $info[2]: $info[0]\n");
                      [$info[0], $info[2], $_, $lasttime] 
                } @files;

my $song_list = Gtk2::SimpleList->new_from_treeview (
    $builder->get_object('tvSongs'),
    'Song' => 'text',
    'Artist' => 'text',
    'Filename' => 'text',
    'Last Play' => 'text',
);

push(@{$song_list->{data}}, @songs);
#push(@{$song_list->{data}}, [ 'árvíztűrő tükörfúrógép' ]);

my $winDisplay = $builder->get_object('winDisplay');
my $winPlayer = $builder->get_object('winPlayer');
$dlgStart->hide();
$winPlayer->show();
Gtk2->main_iteration;

my $player = GStreamer::ElementFactory->make(playbin => 'playbin');
my $bus=$player->get_bus;
$bus->add_signal_watch;
# $bus->signal_connect('message' => \&bus_message);
$bus->signal_connect('message::eos' => \&bus_message);
$bus->signal_connect('message::duration' => \&bus_message);
$bus->signal_connect('message::error' => \&bus_message);
$bus->signal_connect('message::state-changed' => \&bus_message);


my $cc = new Color::Calc(OutputFormat => 'html');
foreach $i (1..5)
{
    $builder->get_object("viewport$i")->modify_bg('normal', ($i == 3) ? Gtk2::Gdk::Color->parse( $Config{'Colors.HighlightBackground'} || 'yellow' ) : Gtk2::Gdk::Color->parse( $Config{'Colors.NormalBackground'} || 'black' ));
}

$builder->get_object("viewport6")->modify_bg('normal', Gtk2::Gdk::Color->parse( $Config{'Colors.HighlightBackground'} || 'yellow' ));
$builder->get_object("viewport7")->modify_bg('normal', Gtk2::Gdk::Color->parse( $Config{'Colors.NormalBackground'} || 'black' ));

Glib::Timeout->add ($period, \&timer);
Gtk2->main;

exit(0);

#########################

sub get_diff_time
{
    my ($diff) = @_;
    
    my $lasttime;
    if ($diff < 3600)
    {
        $lasttime = sprintf("%d mins ago", $diff/60);
    }
    elsif ($diff < 86400)
    {
        $lasttime = sprintf("%2.1lf hours ago", $diff/3600);
    }
    elsif ($diff < 2592000)
    {
        $lasttime = sprintf("%4.1lf days ago", $diff/86400);
    }

    return $lasttime;    
}

sub debug
{
    my $level = shift;
    my @dbg = @_;
    
    if ($level <= $dbglevel)
    {
        $dbg[0] = Term::ANSIColor::color('bold red') . "[" . Term::ANSIColor::color('white') . $level . Term::ANSIColor::color('red') . "]" . Term::ANSIColor::color('reset') . $dbg[0];
        
        printf(@dbg);
        print("\n");
    }
}

sub on_btnLoadMp3_clicked
{
    debug(5, "Load MP3 from file.");
    
    my $filter = Gtk2::FileFilter->new();
    $filter->set_name("Mp3");
    $filter->add_mime_type("audio/mpeg");

    my $file_chooser =  Gtk2::FileChooserDialog->new ('Select an MP3 to open', undef, 'open', 'gtk-cancel' => 'cancel', 'gtk-ok' => 'ok' );
    $file_chooser->add_filter($filter);
    
    my $filename;
    if ($file_chooser->run eq 'ok'){
       $filename = $file_chooser->get_filename;
       print "filename $filename\n";

       my $mp3=MP3::Tag->new($filename);
       my @info=$mp3->autoinfo; 

       push(@{$song_list->{data}}, [$info[0], $info[2], $filename, 0]);

       $playing = scalar(@{$song_list->{data}}) - 1;
       change_song(scalar(@{$song_list->{data}}) - 1, $filename);
    }

    $file_chooser->destroy;    
}

sub on_vbEditor_key_press_event
{
    my($win, $event, $tmp) = @_;

    debug(5, sprintf("Key pressed: %d...", $event->keyval));
    
    # F5: insert new timestamp to the next possible position
    if ($event->keyval == 65474)
    {
        #$sb
        my $lines = $sb->get_line_count();
        my $curpos = $sb->get_iter_at_mark($sb->get_insert());
        my $line = $curpos->get_line();
        my $start = $sb->get_iter_at_line($line);
        my $end = (($lines - 1) > $line ) ? $sb->get_iter_at_line($line+1) : $sb->get_end_iter();
        my $text = $sb->get_text($start, $end, 0);
        my $lineoffset = $curpos->get_line_offset();
        my $newpos;

        my $stamp = sprintf("[%02d:%02d:%03d]", $player_pos / 60000, $player_pos % 60000 / 1000, $player_pos % 1000);

        # debug(5, sprintf("F5: TimePos: %d, Lines: %d, Line: %d, Offset: %d, Text: %s", $player_pos, $lines, $line, $lineoffset, $text));

        # Check if the cursor is at/within a timestamp. If yes, then replace it with the current timestamp
        while ($text =~ /\[\d+:\d+:\d+\]/g) 
        {
            if (($lineoffset >= $-[0]) and ($lineoffset < $+[0]))
            {
                $text = substr($text, 0, $-[0]) . $stamp . substr($text, $+[0]);
                $newpos = $-[0] + length($stamp);
                last;
            }
        }
        
        # If the cursor wasn't in a timestamp, then simply insert the new timestamp where it is.
        if (!$newpos)
        {
            $text = substr($text, 0, $lineoffset) . $stamp . substr($text, $lineoffset);
            $newpos = $lineoffset + length($stamp);
        }

        # Find where to put the cursor after the new timestamp inserted
        # If there is a non-whitespace character after a white-space, then put the cursor there.
        # Or if there is a timestamp, then put the cursor there
        # Or find the end of the line without a timestamp
        my $moved;
        while ($text =~ /\s\K[^\s]|\[\d+:\d+:\d+\]|(?<!\[\d\d:\d\d:\d\d\d\])$/g) 
        {
            if ($-[0] > $newpos)
            {
                $newpos = $-[0];
                $moved = 1;
                last;
            }
        }
        # If we didn't find the next position, then go to the next line
        if (!$moved)
        {
            $newpos = $sb->get_iter_at_line($line+1)->get_offset();
        }
        else
        {
            $newpos += $start->get_offset();
        }

        # $text = $stamp.$text;
        
        $sb->delete($start, $end);
        $sb->insert($start, $text);
        $sb->place_cursor($sb->get_iter_at_offset($newpos));
        $view->scroll_mark_onscreen($sb->get_insert());

    }
    # F6: insert new timestamp to the beginning/end of the lines only
    elsif ($event->keyval == 65475)
    {
        my $lines = $sb->get_line_count();
        my $curpos = $sb->get_iter_at_mark($sb->get_insert());
        my $line = $curpos->get_line();
        my $start = $sb->get_iter_at_line($line);
        my $end = (($lines - 1) > $line ) ? $sb->get_iter_at_line($line+1) : $sb->get_end_iter();
        my $text = $sb->get_text($start, $end, 0);
        my $lineoffset = $curpos->get_line_offset();
        my $newpos;

        my $stamp = sprintf("[%02d:%02d:%03d]", $player_pos / 60000, $player_pos % 60000 / 1000, $player_pos % 1000);

        # debug(5, sprintf("F6: TimePos: %d, Lines: %d, Line: %d, Offset: %d, Text: %s", $player_pos, $lines, $line, $lineoffset, $text));

        # Check if the cursor is at/within a timestamp. If yes, then replace it with the current timestamp
        while ($text =~ /\[\d+:\d+:\d+\]/g) 
        {
            if (($lineoffset >= $-[0]) and ($lineoffset < $+[0]))
            {
                $text = substr($text, 0, $-[0]) . $stamp . substr($text, $+[0]);
                $newpos = $-[0] + length($stamp);
                last;
            }
        }

        # If the cursor wasn't in a timestamp, then simply insert the new timestamp where it is
        if (!$newpos)
        {
            $text = substr($text, 0, $lineoffset) . $stamp . substr($text, $lineoffset);
            $newpos = $lineoffset + length($stamp);
        }

        # Find where to put the cursor after the new timestamp inserted
        my $moved;
        while ($text =~ /\n\K[^\n]|\[\d+:\d+:\d+\]|(?<!\[\d\d:\d\d:\d\d\d\])$/g) 
        {
            if ($-[0] > $newpos)
            {
                $newpos = $-[0];
                $moved = 1;
                last;
            }
        }
        # If we didn't find the next position, then go to the next line
        if (!$moved)
        {
            $newpos = $sb->get_iter_at_line($line+1)->get_offset();
        }
        else
        {
            $newpos += $start->get_offset();
        }

        # $text = $stamp.$text;
        
        $sb->delete($start, $end);
        $sb->insert($start, $text);
        $sb->place_cursor($sb->get_iter_at_offset($newpos));
        $view->scroll_mark_onscreen($sb->get_insert());
    }
    elsif ($event->keyval == 269025062)
    {
        $player->seek(1, 'time', 'flush', 'set', ($player_pos > 10000) ? ($player_pos - 10000) * 1000000 : 0, 'none', 0);
    }
    elsif ($event->keyval == 269025063)
    {
        $player->seek(1, 'time', 'flush', 'set', ($player_pos + 10000) * 1000000, 'none', 0);
    }
}

sub on_btnRemoveTags_clicked
{
    debug(5, "Remove timestamps...");

    my $text = $sb->get_text($sb->get_start_iter, $sb->get_end_iter, 0);
    
    $text =~ s/\[\d+:\d+:\d+\]//g;
    $sb->set_text($text);
}

sub on_btnLoadLyrics_clicked
{
    debug(5, sprintf("Load lyrics from file: %s", $lyrics_fname));
    
    if ($lyrics_fname)
    {
        open(F, $lyrics_fname);
        local $/;
        my $lyrics = <F>;
        close(F);
        utf8::decode($lyrics);
        
        $sb->set_text($lyrics);
        $sb->place_cursor($sb->get_start_iter());
        $view->grab_focus();
    }
}

sub on_btnSaveLyrics_clicked
{
    debug(5, sprintf("Save lyrics to file: %s", $lyrics_fname));
    
    my $retval;
    if (-f $lyrics_fname)
    {
    
        my $dialog = Gtk2::MessageDialog->new_with_markup ($winPlayer, [qw/modal destroy-with-parent/], 'question', 'yes-no', "Overwrite existing file: <b>\n$lyrics_fname</b>");
        $retval = $dialog->run;
        $dialog->destroy;    

        if ($retval eq 'yes')
        {
            rename($lyrics_fname, $lyrics_fname . ".bak-". time());
        }
    }

    if (((-f $lyrics_fname) and ($retval eq 'yes')) or (!-f $lyrics_fname))
    {
        my $lyrics = $sb->get_text($sb->get_start_iter(), $sb->get_end_iter(), 0);
        #print $lyrics;
        open(F, "> $lyrics_fname");
        print(F $lyrics);
        close(F);
    }
    
}

sub on_tbPlay_clicked
{

    my ($result,$state,$pending) = $player->get_state(0);
    debug(5, "Play button clicked ". $builder->get_object('tbPlay')->get_active() . " - " . $state);
    
    if ($builder->get_object('tbPlay')->get_active())
    {
        debug(3, "Play started");
        if ($state eq 'paused')
        {
            $player->set_state("playing");
        }
        elsif ($playing > -1)
        {
            play($playing);
        }
        else
        {
            play_next();
        }
    }
    else
    {
        debug(3, "Play paused");
        $player->set_state("paused");    
    }
}

sub on_winPlayer_delete_event
{
    debug(5, "Exiting...");
    
    $player -> set_state("null");
    Gtk2->main_quit();
}

sub on_tvSongs_row_activated
{
    my ($list, $treepath, $column) = @_;

    my $selected = $song_list->get_row_data_from_path ($treepath)->[2];
    my $fname;
    if ($selected =~ /^\//)
    {
        $fname = $selected;
    }
    else
    {
        $fname = "$song_dir/" . $selected;
    }
    ($playing) = $song_list->get_selected_indices();
    utf8::encode($fname);
    debug(3, "Clicked on: [%d] %s", $playing, $fname);
    change_song($playing, $fname);
}

sub play_file
{
    my ($fname) = @_;

    $player->set_state("null");
    sleep(0.1);
    $player->set(uri => Glib::filename_to_uri $fname, "localhost");
    my $ret = $player->set_state("playing");
    
    debug(5, "Return value of startup: $ret");
    $should_play = 1;

    my $dur_query = GStreamer::Query::Duration -> new("time");
    $player->query($dur_query);
}

sub change_song
{
    my($num, $fname) = @_;

    debug(5, "Starting: %s", $fname);
    $frame = 0;
    $player_dur = 0;
    $capture_time = time();

    my ($shortname) = $fname =~ /.*\/(.*$)/;
    $shortname = $dbh->quote($shortname);
    my $ret = $dbh->selectrow_hashref("select * from PLAYINFO where fname = $shortname");
    my $cmd;
    if (!$ret)
    {
        $cmd = sprintf("insert into PLAYINFO values(%s, %d)", $shortname, int(time())); 
    }
    else
    {
        $cmd = sprintf("update PLAYINFO set lastplay = %d where fname = %s", int(time()), $shortname); 
    }
    debug(6, "SQL: $cmd");
    $dbh->do($cmd);
    # print(Dumper($ret));

    $builder->get_object('tbPlay')->set_active(1);
    play_file($fname);


    $song_list->select($num);

    my ($short_name) = ($fname =~ /^.*?([^\/]+)\.mp3/i);
    $lyrics_fname = $lyrics_dir . "/$short_name.txt";
    
    if (-r $lyrics_fname)
    {
        debug(3, "Opening lyrics file: $lyrics_fname");
        my $mp3 = MP3::Tag->new("$fname"); 
        my @info=$mp3->autoinfo;
        @lines=();
        push(@lines, [ 0, "<span underline='double'>" . $info[2] . " - " . $info[0] . "</span>" ]);
        $builder->get_object('lblTitle')->set_text("<span weight='bold'>" . $info[2] . " - " . $info[0] . "</span>");
        $builder->get_object('lblTitle')->set_use_markup(1);
        open(F, $lyrics_fname);
        %lyrics_options = ();
        while(<F>)
        {
            chomp;
            utf8::decode($_);
            if (/^#/)
            {
                if (/^#OPTION#(\w+):\s+(.+)$/)
                {
                    $lyrics_options{$1} = $2;
                }
                next;
            }
            
            push(@lines, [map { (/(\d+):(\d+):(\d+)/) ? ($1*60+$2)*1000+$3+$lyrics_options{OFFSET} : $_ } (/(\[[0-9:]+\]|[^\[]+)/g)] );
            
        }
        close(F);
        #print Dumper(\@lines);
        print Dumper(\%lyrics_options);
        
        $winDisplay->show();
        my ($width, $height) = $winDisplay->get_size();
        $last_width = 0;
        $last_height = 0;
        resize($width, $height);
    }
    else
    {
        $winDisplay->hide();
        debug(3, "Can't open lyrics file: $lyrics_fname");
    }
}

sub timer
{
    my $pos_query = GStreamer::Query::Position -> new("time");
    $player->query($pos_query);
    $player_pos = int(($pos_query -> position)[1] / 1000000);
      
      
    if ($capturing)
    {
        save_picture();
        my $dt = time() - $capture_time;
        my $ft = $frame * $period / 1000;
        if ($dt > $ft)
        {
            debug(7, "Increase frame counter... ($dt > $ft)");
            save_picture();
        }
        else
        {
            #debug(9, "DT: %lf, FT: %lf, DIFF: %lf", $dt, $ft, ($dt - $ft));
        }
    }
    
    if ($player_state eq 'playing')
    {
        if ($player_dur == 0)
        {
            my $play_pos = $builder->get_object('hsPlayPosition');
            my $dur_query = GStreamer::Query::Duration -> new("time");
            $player->query($dur_query);
            $player_dur = ($dur_query -> duration)[1]/1000000;
            $play_pos->set_range(0, $player_dur);
            debug(5, "Duration: $player_dur");
        }
        my $play_pos = $builder->get_object('hsPlayPosition');
        $play_pos->set_value($player_pos);
        update_lines($player_pos/1000);
        
        my $percent = $player_pos/$player_dur;
        $lyrics_progress->set_position($last_width * $percent);
        #debug(6, "PERCENT: $percent, $last_width, ". $last_width*$percent);
        
    }
        
    return 1;
}

sub on_hsPlayPosition_change_value
{
    print(Dumper(\@_));

    my ($range) = @_;
    
    my $pos = $range->get_value();
    debug(5, "Set position: $pos");
    
    # $player->jump($pos/$player->tpf);
    # $player->seek(1, 'time', 'flush', 'set', ($player_pos > 10000) ? ($player_pos - 10000) * 1000000 : 0, 'none', 0);
            
    return 0;
}

sub on_winDisplay_delete_event
{
    my($win) = @_;

    $win->hide();
    return 1;
}

sub on_winDisplay_configure_event
{
    my($win, $event, $data) = @_;

    my $width = $event->width;
    my $height = $event->height;

    resize($width, $height);
    
    return 0;
}


sub resize
{
    my ($width, $height) = @_;
    
    if ($width == $last_width and $height == $last_height)
    {
        return;
    }
    
    $last_width = $width;
    $last_height = $height;
    
    my $area = new Gtk2::DrawingArea; #don't confuse with Gtk2::Drawable
    my $pixmap = Gtk2::Gdk::Pixmap->new( $winDisplay->window, $width, $height, -1 );
    my $pango_layout = $area->create_pango_layout("");
    my $gc =  new Gtk2::Gdk::GC ($pixmap);
    my $pos = 0;
    my $fontsize;
    my $text_width = 0;
    my $text_height = 0;
    my $fs = 99;
    for (my $i=0; $i<=$#lines; $i++)
    {
        my $line = get_line($i, 0);
        $fontsize = 14;
        # print Dumper $_;
        $pango_layout->set_text ($line);
        #$text_width = 0;
        #$text_height = 0;
        
        if ($line =~ /^\s*$/)
        {
            next;
        }
        while (($text_width < $width) and ($fontsize < 100))
        {
           my $font_desc = Gtk2::Pango::FontDescription->from_string("Arial Bold");
           $pango_layout->set_font_description($font_desc);
           my $f = $fontsize * 1024;
           $pango_layout->set_markup ("<span foreground=\"black\" background=\"yellow\" size=\"$f\"><b>" . $line . '</b></span>');
           ($text_width, $text_height) = $pango_layout->get_pixel_size();
           #print("+++ Testing: FontSize: $fontsize, TWidth: $text_width x $text_height - $_->[1]\n");
           $fontsize += 2;
        }
        while (($text_width > $width) and ($fontsize > 4))
        {
           my $font_desc = Gtk2::Pango::FontDescription->from_string("Arial Bold");
           $pango_layout->set_font_description($font_desc);
           my $f = $fontsize * 1024;
           $pango_layout->set_markup ("<span foreground=\"black\" background=\"yellow\" size=\"$f\"><b>" . $line . '</b></span>');
           ($text_width, $text_height) = $pango_layout->get_pixel_size();
           #print("--- Testing: FontSize: $fontsize, TWidth: $text_width x $text_height - $_->[1]\n");
           $fontsize -= 2;
        }
        #$pixmap->draw_layout($gc,0,$pos, $pango_layout);
        #$pos += $text_height;
        #print("Q: $text_width - $fontsize - $fs - ".$_->[1]."\n");
        $text_width = 0;
        $fs = ($fontsize < $fs) ? $fontsize : $fs;
    }
    $fs = int($fs*0.9);
    debug(5, "Calculated fontsize: $fs");
    $area = undef;
    $pango_layout = undef;

    my $al = Pango::AttrList->new();
    my $x = Pango::AttrSize->new($fs*1000);
    $al->insert($x);
    my $x = Pango::AttrWeight->new('bold');
    $al->insert($x);
    my $al_inverse = $al->copy();
    my $cc = new Color::Calc(OutputFormat => 'tuple');
    my @color = map { $_ * 0xFF } $cc->get($Config{'Colors.NormalText'} || 'yellow');
    debug(5, "COLOR: ", join(",", @color));
    my $x = Pango::AttrForeground->new(@color);
    $al->insert($x);
    foreach my $i (1..5)
    {
        $builder->get_object("lblLine$i")->set_attributes(($i == 3) ? $al_inverse : $al);
    }
}

sub on_winDisplay_key_press_event
{
    my ($win, $event) = @_;

    # print Dumper($event->keyval);
    if ($event->keyval == 65480 and $winDisplay->{fs} == 0)
    {
        $winDisplay->fullscreen();
        $winDisplay->{fs} = 1;
    }
    elsif ($event->keyval == 65480 and $winDisplay->{fs} == 1)
    {
        $winDisplay->unfullscreen();
        $winDisplay->{fs} = 0;
    }
    elsif ($event->keyval == 78 or $event->keyval == 110)
    {
        play_next();
    }
    elsif ($event->keyval == 65515)
    {
        #my $lpixbuf = Gtk2::Gdk::Pixbuf->new('rgb', 0, 8, 20, 20);
        #my @a = $lpixbuf->get_formats();
        #print Dumper(\@a);
        
        $capturing = not $capturing;
        if ($capturing) 
        {
            $winDisplay->set_title("Karaoke - Capturing");
            $player->seek(1, 'time', 'flush', 'set', 0, 'none', 0);
            $capture_time = time();
            #$winDisplay->resize(720, 576);
        }
        else
        {
            $winDisplay->set_title("Karaoke");
        }
    }
    ### FAST FORWARD
    elsif ($event->keyval == 65363)
    {
        $player->seek(1, 'time', 'flush', 'set', ($player_pos + 10000) * 1000000, 'none', 0);
        #$player->jump('+500');
    }
    ### REWIND
    elsif ($event->keyval == 65361)
    {
        $player->seek(1, 'time', 'flush', 'set', ($player_pos > 10000) ? ($player_pos - 10000) * 1000000 : 0, 'none', 0);
        #$player->jump('-500');
    }
    ### END
    elsif ($event->keyval == 65367)
    {
        $player->seek(1, 'time', 'flush', 'set', ($player_dur - 10000) * 1000000, 'none', 0);
        debug(7, "Jumping to the end");
    }
    ### HOME
    elsif ($event->keyval == 65360)
    {
        $player->seek(1, 'time', 'flush', 'set', 0, 'none', 0);
        debug(7, "Jumping to the beginning");
    }
    
    return 0;
}

sub on_winDisplay_event
{
    my ($win, $event) = @_;
    
    # print Dumper($event);
}

sub update_lines
{
    my($time) = @_;
    
    my $i = 0;
    for ($i=0; $i<=$#lines; $i++)
    {
        #print Dumper $lines[$i];
        if ($lines[$i]->[0] > ($time*1000+$time_offset) )
        {
            # print("D: $i - ".$lines[$i]->[1]."-".$lines[$i]->[0]."\n");
            last;
        }
    }
    $i--;

    #debug(10, "Line: $i - %d", $#lines);
    #if (($last_line == $i) and ($lines[$i]->[1] !~ /^\s*$/)) 
    #{
    #    return;
    #}
    $last_line = $i;
    my $next_time;
    if ($i+1 <= $#lines)
    {
        $next_time = $lines[$i+1]->[0];
    }
    
    $dirty = 0;
    foreach my $i (1..5)
    {
        my $old_content = $builder->get_object("lblLine$i")->get_label();
        my $curline = $last_line - 3 + $i;
        if (($curline >= 0) and ($curline <= $#lines))
        {
            if (($i != 3) or ($lines[$curline]->[1] !~ /^\s*$/))
            {
                my $line = get_line($curline, ($i == 3) ? $time : 0);
                if ($line ne $old_content)
                {
                    $dirty=1;
                    $builder->get_object("lblLine$i")->set_label($line);
                    #print(DBG "$i : $line\n");
                }
            }
            else
            {
                my $timestr;
                my @timechars = qw(➉ ⑪ ⑫ ⑬ ⑭ ⑮ ⑯ ⑰ ⑱ ⑲ ⑳ ㉑ ㉒ ㉓ ㉔ ㉕ ㉖ ㉗ ㉘ ㉙ ㉚ ㉛ ㉜ ㉝ ㉞ ㉟ ㊱ ㊲ ㊳ ㊴ ㊵ ㊶ ㊷ ㊸ ㊹ ㊺ ㊻ ㊼ ㊽ ㊾ ㊿);
                my $diff = int(($next_time - $time * 1000)/1000) + 1;
                if ($diff > 9)
                {
                    $timestr = (($diff % 2) ?  "◉ " : "● ");
                    $timestr .= "● " x 9;
                    #$timestr .= $timechars[$diff-10];
                    $timestr .= "($diff)";
                }
                else
                {
                    $timestr = "● " x $diff;
                }
                my $cc = new Color::Calc(OutputFormat => 'html');
                my $bullets_color = $Config{'Colors.Bullets'} || 'black';
                $timestr = "<span foreground='$bullets_color'>".$timestr."</span>";
                
                if ($timestr ne $old_content)
                {
                    $dirty=1;
                    $builder->get_object("lblLine$i")->set_label($timestr);
                }
            }
        }
        else
        {
            if ('' ne $old_content)
            {
                $dirty=1;
                $builder->get_object("lblLine$i")->set_label('');
            }
        }
    }
    
}

sub play
{
    my $fname=$song_dir . "/" . @{$song_list->{data}}[$playing]->[2];
    utf8::encode($fname);
    debug(3, "Playing next song: [%d] %s", $playing, $fname);
    change_song($playing, $fname);
}

sub play_next
{
    if ($builder->get_object('tbShuffle')->get_active())
    {
        # $playing = int(rand(scalar(@{$song_list->{data}})));
        my $next = rand(scalar(@rnd));
        $playing = $rnd[$next];
        $rnd[$next] = $rnd[$#rnd];
        pop(@rnd);
        debug(3, "Random queue len: %d", scalar(@rnd));
        if (scalar(@rnd) <= 1)
        {
            debug(5, "Reinitializing random queue (qlen: %d, play: %d)", scalar(@songs), $playing);
            @rnd = (0 .. $#songs);
        }
    }
    else
    {
        $playing++;
    }
    
    play($playing);
}

sub on_btnNext_clicked
{
    play_next();
}

sub save_picture
{
    if (!$playing)
    {
        return;
    }

    my $dirname = @{$song_list->{data}}[$playing]->[1] . "_" . @{$song_list->{data}}[$playing]->[2];
    my $name = sprintf("%s/%010d.png", $dirname, $frame++);


    if ($dirty)
    {
        my ($width, $height) = $winDisplay->window->get_size();
        if (! -d $dirname)
        {
            mkdir($dirname);
        }

        my $lpixbuf = Gtk2::Gdk::Pixbuf->new('rgb', 0, 8, $width, $height);

        $lpixbuf->get_from_drawable ($winDisplay->window, undef, 0, 0, 0, 0, $width, $height);

        #only jpeg and png is supported !!!! it's 'jpeg', not 'jpg'
        #$lpixbuf->save ("$prefix-area.jpg", 'jpeg', quality => 100);
        $lpixbuf->save ($name, 'png');
        $last_frame = $name;
    }
    elsif ($last_frame ne '')
    {
        link($last_frame, $name);
    }
    
    ## Put everything into a video:
    ## ffmpeg2theora -F 10 -v 10 '%010d.png' -o tmp.ogv
    ## mpg123 -w 'audio.wav' '/home/major/Music/Karaoke/Mate Peter - Zene nelkul mit erek en.mp3'
    ## oggenc audio.wav
    ## oggz-merge -o v.ogv tmp.ogv audio.ogg
    
    return($frame);
}

sub get_line
{
    my($line_num, $time) = @_;
    
    $time *= 1000;
    my $line = $lines[$line_num];
    my $nextline = $lines[$line_num + 1];
    my $nextstart;
    if ($nextline)
    {
        $nextstart = $nextline->[0];
    }
    my $ret = "";

    my $cc = new Color::Calc(OutputFormat => 'html');
    my $progress_color = $Config{'Colors.Progress'} || 'red';
    my $foreground = $Config{'Colors.HighlightForeground'} || 'black';
    if ($time == 0)
    {
        for ($i=1; $i <= $#$line; $i += 2)
        {
            $ret .= $line->[$i];
        }
    }
    else
    {
        my $span = 0;
        for ($i=1; $i <= $#$line; $i += 2)
        {
            if ($time > $line->[$i-1] and $time < $line->[$i+1])
            {
                my $linelen = length($line->[$i]);
                my $linetime = $line->[$i+1] - $line->[$i-1];
                my $t = $time - $line->[$i-1];
                my $pos = int($linelen * $t / $linetime);
                #debug(10, "LEN: $linelen, TIME: $time, $linetime, POS: $pos");

                $ret = "<span foreground='$progress_color'>$ret" . substr($line->[$i], 0, $pos) . "</span><span foreground='$foreground'>" . substr($line->[$i], $pos);
                $span = 1;
            }
            elsif (($i == $#$line - 1) and ($time > $line->[$i+1]))
            {
                $ret = "<span foreground='$progress_color'>$ret" . $line->[$i] . "</span>";
            }
            else
            {
                #$ret .= "<span foreground='$foreground'>".$line->[$i]."</span>";
                if ((defined $nextstart) and ($#$line == 1))
                {
                    my $linelen = length($line->[$i]);
                    my $linetime = $nextstart - $line->[$i-1];
                    my $t = $time - $line->[$i-1];
                    my $pos = int($linelen * $t / $linetime);
                    $ret = "<span foreground='$progress_color'>$ret" . substr($line->[$i], 0, $pos) . "</span>" . substr($line->[$i], $pos);
                }
                else
                {
                    $ret .= $line->[$i];                
                }
            }
        }
        if ($span)
        {
            $ret .= "</span>";
        }
        else
        {
            $ret = "<span foreground='$foreground'>$ret</span>";
        }
    }

    return($ret);
}

sub bus_message
{
    my ($bus, $message) = @_;
    # print Dumper(@_);
    
    if ($message->type & "tag")
    {
        print($message->tag_list->{artist}->[0]."\n");
    }
    elsif ($message->type & "state-changed")
    {
        $player_state = $message->new_state;
    }
    elsif ($message->type & "eos")
    {
        play_next();
    }
}

sub on_ebEditor_key_press_event
{
    # print Dumper(\@_);
    
    
}
