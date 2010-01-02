#!/usr/bin/perl

use Data::Dumper;
use Term::ANSIColor;
use Audio::Play::MPG123;
use MP3::Tag;
use Time::HiRes qw ( time alarm sleep );

use Glib qw/TRUE FALSE/;
use Gtk2 '-init';
use Gtk2::SimpleList;

use strict;
use utf8;

$|=1;
my $song_dir = '/home/major/Music/Karaoke';
my $lyrics_dir = '/home/major/Documents/lyrics';
my $period = 100; # millisec
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
my $max_frame = 0;

my $glade_file = 'myplayer.glade';

my $builder = Gtk2::Builder->new();
my $i = $builder->add_from_file ($glade_file);
$builder->connect_signals();

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
                      my $mp3=MP3::Tag->new("$song_dir/$_"); 
                      my @info=$mp3->autoinfo; 
                      $progress->set_text("$cnt/$#files");
                      $progress->set_fraction($cnt++/$#files);
                      Gtk2->main_iteration;
                      utf8::decode($_); 
                      [$info[0], $info[2], $_] 
                } @files;

my $song_list = Gtk2::SimpleList->new_from_treeview (
    $builder->get_object('tvSongs'),
    'Song' => 'text',
    'Artist' => 'text',
    'Filename' => 'text',
);

push(@{$song_list->{data}}, @songs);
#push(@{$song_list->{data}}, [ 'árvíztűrő tükörfúrógép' ]);

my $winDisplay = $builder->get_object('winDisplay');
my $winPlayer = $builder->get_object('winPlayer');
$dlgStart->hide();
$winPlayer->show();
Gtk2->main_iteration;

my $player = new Audio::Play::MPG123(mpg123args => ['-o', 'esd'] );


foreach $i (1..5)
{
    $builder->get_object("viewport$i")->modify_bg('normal', ($i == 3) ? Gtk2::Gdk::Color->parse( 'yellow' ) : Gtk2::Gdk::Color->parse( 'black' ));
}

Glib::Timeout->add ($period, \&timer);
Gtk2->main;

exit(0);

#########################

sub debug
{
    my $level = shift;
    my @dbg = @_;
    
    $dbg[0] = color('bold red') . "[" . color('white') . $level . color('red') . "]" . color('reset') . $dbg[0];
    
    printf(@dbg);
    print("\n");
}

sub on_winPlayer_delete_event
{
    debug(5, "Exiting...");
    
    Gtk2->main_quit();
}

sub on_tvSongs_row_activated
{
    my ($list, $treepath, $column) = @_;

    my $fname = "$song_dir/" . $song_list->get_row_data_from_path ($treepath)->[2];
    ($playing) = $song_list->get_selected_indices();
    utf8::encode($fname);
    debug(3, "Clicked on: [%d] %s", $playing, $fname);
    change_song($playing, $fname);
}

sub change_song
{
    my($num, $fname) = @_;

    debug(5, "Starting: %s", $fname);
    $frame = 0;
    $capture_time = time();

    my $ret = $player->load($fname);
    debug(5, "Return value of startup: $ret");
    $should_play = 1;
    $player->poll(1);
    #print Dumper($player);
    my $play_pos = $builder->get_object('hsPlayPosition');
    $play_pos->set_range($player->frame->[2], $player->frame->[3]);
    $play_pos->set_value($player->frame->[2]);
    $song_list->select($num);
    $max_frame = $player->frame->[1];

    my ($short_name) = ($fname =~ /^.*?([^\/]+)\.mp3/i);
    my $lyrics_fname = $lyrics_dir . "/$short_name.txt";
    
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
        while(<F>)
        {
            chomp;
            utf8::decode($_);
            
            push(@lines, [map { (/(\d+):(\d+):(\d+)/) ? ($1*60+$2)*1000+$3 : $_ } (/(\[[0-9:]+\]|[^\[]+)/g)] );
            
        }
        close(F);
        #print Dumper(\@lines);
        
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
    $player->poll(0); 
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
    
    if ($player->state == 2)
    {
        $curr_time = $player->{frame}->[2];
        my $play_pos = $builder->get_object('hsPlayPosition');
        $play_pos->set_value($curr_time);
        update_lines($curr_time);
    }
    elsif ($player->state == 0)
    {
        if ($should_play == 1)
        {
            play_next();
        }
        #debug(5, "State: ".$player->state);
    }
        
    return 1;
}

sub on_hsPlayPosition_change_value
{
    my ($range) = @_;
    
    my $pos = $range->get_value();
    
    $player->jump($pos/$player->tpf);
    
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
    my $x = Pango::AttrForeground->new(0xFFFF, 0xFFFF, 0x0);
    $al->insert($x);
    #my $x = Pango::AttrForeground->new(0x0, 0x0, 0x0);
    #$al_inverse->insert($x);
    foreach my $i (1..5)
    {
        $builder->get_object("lblLine$i")->set_attributes(($i == 3) ? $al_inverse : $al);
    }
}

sub on_winDisplay_key_press_event
{
    my ($win, $event) = @_;

    print Dumper($event->keyval);
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
            $player->jump(0);
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
        $player->jump('+500');
    }
    ### REWIND
    elsif ($event->keyval == 65361)
    {
        $player->jump('-500');
    }
    ### END
    elsif ($event->keyval == 65367)
    {
        $player->jump($max_frame - 500);
        debug(7, "Jumping to the end (frame: %d)", $max_frame - 500);
    }
    ### HOME
    elsif ($event->keyval == 65360)
    {
        $player->jump(0);
        debug(7, "Jumping to the beginning");
    }
    
    return 0;
}

sub on_winDisplay_event
{
    my ($win, $event) = @_;
    
    print Dumper($event);
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
                }
            }
            else
            {
                my $timestr;
                my $diff = int(($next_time - $time * 1000)/1000) + 1;
                if ($diff > 9)
                {
                    $timestr = (($diff % 2) ?  "◉ " : "● ");
                    $timestr .= "● " x 9;
                }
                else
                {
                    $timestr = "● " x $diff;
                }
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

sub play_next
{
    if ($builder->get_object('tbShuffle')->get_active())
    {
        $playing = int(rand(scalar(@{$song_list->{data}})));
    }
    else
    {
        $playing++;
    }
    my $fname=$song_dir . "/" . @{$song_list->{data}}[$playing]->[2];
    utf8::encode($fname);
    debug(3, "Playing next song: [%d] %s", $playing, $fname);
    change_song($playing, $fname);
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
    my $ret = "";
    if ($time == 0)
    {
        for ($i=1; $i <= $#$line; $i += 2)
        {
            $ret .= $line->[$i];
        }
    }
    else
    {
        for ($i=1; $i <= $#$line; $i += 2)
        {
            if ($time > $line->[$i-1] and $time < $line->[$i+1])
            {
                my $linelen = length($line->[$i]);
                my $linetime = $line->[$i+1] - $line->[$i-1];
                my $t = $time - $line->[$i-1];
                my $pos = int($linelen * $t / $linetime);
                # debug(10, "LEN: $linelen, TIME: $time, $linetime, POS: $pos");
                $ret = "<span foreground='red'>$ret" . substr($line->[$i], 0, $pos) . "</span>" . substr($line->[$i], $pos);
            }
            elsif (($i == $#$line - 1) and ($time > $line->[$i+1]))
            {
                $ret = "<span foreground='red'>$ret" . $line->[$i] . "</span>";
            }
            else
            {
                $ret .= $line->[$i];
            }
        }
    }
    
    return($ret);
}
