Unfortunately, the gen_socket, and gen_netlink typespecs are too broken to be useful right now. I removed them from rebar dialyze from the circle.yml because of this.
If you want to run dialyzer, go through the following:
```
./rebar compile build-plt
dialyzer --plt .rebar/minuteman_18.1_plt --remove_from_plt -r deps/gen_netlink/
dialyzer --plt .rebar/minuteman_18.1_plt --remove_from_plt -r deps/gen_socket/
```

When you want to run it, simply:
```
./rebar compile &&  dialyzer --plt .rebar/minuteman_18.1_plt --add_to_plt ebin/ --verbose && ./rebar dialyze 
```
