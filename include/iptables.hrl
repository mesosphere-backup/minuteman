-type table()           :: filter | nat | mangle | raw | security.
-type chain()           :: prerouting | input | forward | output |
                           postrouting | atom().
-type target()          :: accept | drop | return.

%-type protocol()        :: tcp | udp | udplite | icmp | esp | ah | sctp | all.
%-type command()         :: append | check | delete | insert | replace |
%                           list | flush | zero | new_chain | delete_chain |
%                           policy | rename_chain.
%-type target()          :: accept | drop | queue | nfqueue | return.
%-type state()           :: established | invalid | new | related.
%-type interface()       :: string().
%-type interface_type()  :: in | out.
