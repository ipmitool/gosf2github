#!/usr/bin/perl -w
use strict;
use JSON;
use HTTP::Request;
use Data::Dumper;
use LWP;
use Getopt::Long qw(:config gnu_getopt);
use DateTime::Format::Strptime qw/strptime strftime/;

my $json = new JSON;

my $GITHUB_TOKEN;
my $REPO;
my $dry_run=0;
my @collabs = ();
my @ghmilestones = ();
my $sleeptime = 3;
my $default_assignee;
my $usermap = {};
my $only_milestones = 0;
my $sf_base_url = "https://sourceforge.net/p/";
my $sf_tracker = "";  ## e.g. obo/mouse-anatomy-requests
my @default_labels = ('sourceforge', 'auto-migrated');
my $genpurls;
my $start_from = 1;
my $include_closed = 0;
my $verbose = 0;

sub usage($);

if (!(@ARGV)) { usage(1); }

GetOptions ("h|help" => sub { usage(0); },
            "t|token=s" => \$GITHUB_TOKEN,
            "r|repo=s" => \$REPO,
            "a|assignee=s" => \$default_assignee,
            "s|sf-tracker=s" => \$sf_tracker,
            "d|delay=i" => \$sleeptime,
            "i|initial-ticket=i" => \$start_from,
            "l|label=s" => \@default_labels,
            # if you are not part of the OBO Library project, you can safely ignore this -g option;
            # It will replace IDs of form FOO:nnnnn with PURLs
            "g|generate-purls" => \$genpurls,
            "c|collaborators=s" => sub { @collabs = @{parse_json_file($_[1])} },
            "u|usermap=s" => sub { $usermap = parse_json_file($_[1]) },
            "m|milestones=s" => sub { @ghmilestones = @{parse_json_file(shift @ARGV)} },
            "M|only-milestones" => \$only_milestones,
            "C|include-closed" => \$include_closed,
            "v|verbose" => \$verbose,
            "k|dry-run" => \$dry_run)
or usage(1);

print STDERR "TICKET JSON: @ARGV\n";

my %collabh = ();
foreach (@collabs) {
    $collabh{$_->{login}} = $_;
}

my $blob = join("",<>);
my $obj = $json->decode( $blob );

my @tickets = @{$obj->{tickets}};
my @milestones = @{$obj->{milestones}};

my %closed_statuses;
if ($obj->{closed_status_names}) {
    %closed_statuses = map { $_ => 1 } split(" ", $obj->{closed_status_names});
} else {
    %closed_statuses = map { $_ => 1 } qw(Fixed Done WontFix Verified Duplicate Invalid);
}

if ($only_milestones) {
    import_milestones();
    exit 0;
}

my %ghmilestones = ();
foreach (@ghmilestones) {
    $ghmilestones{$_->{title}} = $_;

#foreach my $k (keys %$obj) {
#    print "$k\n";
#}

@tickets = sort {
    $a->{ticket_num} <=> $b->{ticket_num}
} @tickets;

if (!$default_assignee) {
    die("You must specify a default assignee using the -a option");
}

foreach my $ticket (@tickets) {

    my $closed = $closed_statuses{$ticket->{status}} ? JSON::true : JSON::false;

    if ($closed && !$include_closed) {
        print "Skipping closed ticket #".$ticket->{ticket_num}." ".$ticket->{summary}."\n";
        next;
    }

    my $custom = $ticket->{custom_fields} || {};
    my $milestone = $custom->{_milestone};

    my @labels = (@default_labels,  @{$ticket->{labels}});

    push(@labels, map_priority($custom->{_priority}));

    my $assignee = map_user($ticket->{assigned_to});
    if (!$assignee || !$collabh{$assignee}) {
        #die "$assignee is not a collaborator";
        $assignee = $default_assignee;
    }

    my $body = $ticket->{description};

    # fix SF-specific markdown
    $body =~ s/\~\~\~\~/```/g;

    if ($genpurls) {
        my @lines = split(/\n/,$body);
        foreach (@lines) {
            last if m@```@;
            next if m@^\s\s\s\s@;
            s@(\w+):(\d+)@[$1:$2](http://purl.obolibrary.org/obo/$1_$2)@g;
        }
        $body = join("\n", @lines);
    }

    my $created_date = $ticket->{created_date};

    # OK, so I should really use a proper library here...
    $created_date =~ s/\-//g;
    $created_date =~ s/\s.*//g;

    # Prepend all the info regarding the original ticket

    my $header;
    my $orig_reporter = map_user($ticket->{reported_by});
    $header .= bold("Reported by:")." ".user($orig_reporter);

    my $num = $ticket->{ticket_num};
    printf "Ticket: ticket_num: %d of %d total (last ticket_num=%d)\n", $num, scalar(@tickets), $tickets[-1]->{ticket_num};
    if ($num < $start_from) {
        print STDERR "SKIPPING: $num\n";
        next;
    }
    if ($sf_tracker) {
        my $turl = "$sf_base_url$sf_tracker/$num";
        $header .= "\n".bold("Original Ticket:")." [$sf_tracker/$num]($turl)";
    }

    my $issue =
    {
        "title" => $ticket->{summary},
        "body" => $header."\n\n".$body,
        "created_at" => cvt_time($ticket->{created_date}),    ## check
        "assignee" => $assignee,
        "closed" => $closed,
        "labels" => \@labels,
    };

    # Declare milestone if possible
    if ($ghmilestones{$milestone}) {
        $issue->{milestone} = $ghmilestones{$milestone}->{number};
    }
    # Else, use a tag
    elsif ($milestone) {
        push(@{$issue->{labels}}, $milestone);
    }

    my @comments = ();
    foreach my $post (@{$ticket->{discussion_thread}->{posts}}) {
        my $commenter = map_user($post->{author});
        my $comment =
        {
            "created_at" => cvt_time($post->{timestamp}),
            "body" => $post->{text}."\n\n".bold("Original comment by:")." ".user($commenter)
        };
        push(@comments, $comment);
    }

    my $content = {
        issue => $issue,
        comments => \@comments
    };
    my $str = $json->utf8->encode($content);

    #  https://gist.github.com/jonmagic/5282384165e0f86ef105

    my $ua = LWP::UserAgent->new;
    my $gh_url = "https://api.github.com/repos/$REPO/import/issues";

    $ua->agent("sf2gh/1.0");
    my $req = HTTP::Request->new(POST => $gh_url);
    $req->header(Accept => "application/vnd.github.golden-comet-preview+json");
#    $req->header(Accept => "application/vnd.github.v3+json");
    $req->header(Authorization => "token $GITHUB_TOKEN");
    $req->content($str);
    print Dumper($req) if $verbose;

    if ($dry_run) {
        print "DRY RUN: not executing\n";
    }
    else {
        my $retry = 1;
        my $res;

        TRY: {
            do {
                $res = $ua->request($req);

                if ($res->is_success) {
                    print "SUCCESS\n";
                    last TRY;
                }
            } while($retry-- && sleep(5 * $sleeptime))
        }

        if (!$res->is_success) {
            print STDERR "FAILED: $res->status_line\n";
            print STDERR "To resume, use the -i $num option\n";
            exit(1);
        }
        sleep($sleeptime);
    }
}

exit 0;

sub import_milestones {

    foreach(@milestones) {
        my $milestone = {
            "title" => $_->{name},
            "state" => $_->{complete} ? 'closed' : 'open',
            "description" => $_->{description},
        };

        # Add due_date if defined
        if ($_->{due_date}) {
            my $dt = strptime("%m/%d/%Y", $_->{due_date});
            $milestone->{due_on} = strftime("%FT%TZ", $dt);
        }

        my $str = $json->utf8->encode($milestone);
        my $jsfile = 'foo.json';
        open(F,">$jsfile") || die $jsfile;
        print F $str;
        close(F);

        my $ACCEPT = "application/vnd.github.v3+json";   # https://developer.github.com/v3/
        my $command = "curl -X POST -H \"Authorization: token $GITHUB_TOKEN\" -H \"Accept: $ACCEPT\" -d \@$jsfile https://api.github.com/repos/$REPO/milestones\n";
        print $command;
        if ($dry_run) {
            print "DRY RUN: not executing\n";
            print "$str\n";
        }
        else {
            # yes, I'm really doing this via a shell call to curl, and not
            # LWP or similar, I prefer it this way
            my $err = system($command);
            if ($err) {
                print STDERR "FAILED: $command\n";
                print STDERR "Retrying once...\n";
                # HARDCODE ALERT: do a single retry
                sleep($sleeptime * 5);
                $err = system($command);
                if ($err) {
                    print STDERR "FAILED: $command\n";
                    exit(1);
                }
            }
        }
        #die;
        sleep($sleeptime);
    }

}

sub parse_json_file {
    my $f = shift;
    open(F,$f) || die $f;
    my $blob = join('',<F>);
    close(F);
    return $json->decode($blob);
}

sub map_user {
    my $u = shift;
    my $ghu = $u ? $usermap->{$u} : $u;
    if ($ghu && $ghu eq 'nobody') {
        $ghu = $u;
    }
    return $ghu || $u;
}

sub cvt_time {
    my $in = shift;  # 2013-02-13 00:30:16
    $in =~ s/ /T/;
    return $in."Z";
    
}

# customize this?
sub map_priority {
    my $pr = shift;
    return ();
}

sub scriptname {
    my @p = split(/\//,$0);
    pop @p;
}

sub user
{
    my $username = shift;
    # it is tempting to prefix with '@' but this may generate spam and get the bot banned
    return "[$username](https://github.com/$username)";
}

sub bold
{
    my $text = shift;
    return "**".$text."**";
}

sub usage($) {
    my $sn = scriptname();

    print <<EOM;
$sn [-h] [-u USERMAP] [-m MILESTONES] [-c COLLABINFO]
    [-r REPO] [-t OAUTH_TOKEN] [-a USERNAME] [-l LABEL]*
    [-s SF_TRACKER] [--dry-run] [--only-milestones] TICKETS-JSON-FILE

Migrates tickets from sourceforge to github, using new v3 GH API,
documented here: https://gist.github.com/jonmagic/5282384165e0f86ef105

Requirements:

 * This assumes that you have exported your tickets from SF.
   E.g. from a page like this: https://sourceforge.net/p/obo/admin/export
 * You have a github account and have created an OAuth token here:
   https://github.com/settings/tokens

Example Usage:

curl -H "Authorization: token TOKEN" \
     https://api.github.com/repos/obophenotype/cell-ontology/collaborators \
     > cell-collab.json
gosf2github.pl -a cmungall -u users_sf2gh.json -c cell-collab.json \
               -r obophenotype/cell-ontology -t YOUR-TOKEN-HERE \
               cell-ontology-sf-export.json

ARGUMENTS:

   -k | --dry-run
                 Do not execute github API calls
                 Only parse tickets and dump requests (if -v is specified)

   -r | --repo   REPO *REQUIRED*
                 Examples: cmungall/sf-test, obophenotype/cell-ontology

   -t | --token  TOKEN *REQUIRED*
                 OAuth token. Get one here: https://github.com/settings/tokens
                 Note that all tickets and issues will appear to originate
                 from the user that generates the token.  Important: make sure
                 the token has the public_repo scope.

   -l | --label  LABEL
                 Add this label to all tickets, in addition to defaults and
                 auto-added.  Currently the following labels are ALWAYS added:
                 auto-migrated, a priority label (unless priority=5), a label
                 for every SF label, a label for the milestone

   -u | --usermap USERMAP-JSON-FILE *RECOMMENDED*
                  Maps SF usernames to GH Example:
                  https://github.com/geneontology/go-site/blob/master/metadata/users_sf2gh.json

   -m | --milestones MILESTONES-JSON-FILE/
                 If provided, link ticket to proper milestone. It not,
                 milestone will be declared as a ticket label.
                 Generate like this:
                 curl -H "Authorization: token TOKEN" \
                      https://api.github.com/repos/cmungall/sf-test/milestones?state=all \
                      > milestones.json

   -a | --assignee  USERNAME *REQUIRED*
                 Default username to assign tickets to if there is no mapping
                 for the original SF assignee in usermap

   -c | --collaborators COLLAB-JSON-FILE *REQUIRED*
                  Required, as it is impossible to assign to a non-collaborator
                  Generate like this:
                  curl -H "Authorization: token TOKEN" \
                       https://api.github.com/repos/cmungall/sf-test/collaborators \
                       > sf-test-collab.json

   -i | --initial-ticket  NUMBER
                 Start the import from (sourceforge) ticket number NUM.  This
                 can be useful for resuming a previously stopped or failed
                 import.  For example, if you have already imported 1-100, then
                 the next github number assigned will be 101 (this cannot be
                 controlled). You will need to run the script again with
                 argument: -i 101

   -C | --include-closed
                 By default, closed issues are not imported.
                 Specify this option to import them.

   -s | --sf-tracker  NAME
                 E.g. obo/mouse-anatomy-requests
                 If specified, will append the original URL to the body of the
                 new issue. E.g.:
                 https://sourceforge.net/p/obo/mouse-anatomy-requests/90

   -v | --verbose
                 If specified, enables verbose output. That, for instance,
                 includes dumping of requests to GitHub to console for
                 debugging purposes

   -M | --only-milestones
                 Only import milestones defined in data exported from SF,
                 from TICKETS-JSON-FILE. Useful to run this script first,
                 with this flag to populate GitHub milestones and use them
                 really imported SF tickets.

   --generate-purls
                 OBO Ontologies only: converts each ID of the form
                 `FOO:nnnnnnn` into a PURL. If this means nothing to you,
                 the option is not intended for you. You can safely ignore it.

NOTES:

 * uses a pre-release API documented here:
   https://gist.github.com/jonmagic/5282384165e0f86ef105
 * milestones are converted to labels
 * all issues and comments will appear to have originated from the user who
   issues the OAth ticket
 * NEVER RUN TWO PROCESSES OF THIS SCRIPT IN THE SAME DIRECTORY - see notes
   on json hack below

HOW IT WORKS:

The script iterates through every ticket in the json dump. For each
ticket, it prepares an API post request to the new GitHub API and
posts it using LWP.

The script will then sleep for 3s before continuing on to the next ticket.
 * all issues and comments will appear to have originated from the user who
   issues the OAuth token

TIP:

Note that the API does not grant permission to create the tickets as
if they were created by the original user, so if your token was
generated from your account, it will look like you submitted the
ticket and comments.

Create an account for an agent like https://github.com/bbopjenkins -
use this account to generate the token. This may be better than having
everything show up under your own personal account

CREDITS:

Author: [Chris Mungall](https://github.com/cmungall)
Inspiration: https://github.com/ttencate/sf2github
Thanks: Ivan Žužak (GitHub support), Ville Skyttä (https://github.com/scop)

EOM
exit(shift);
}
