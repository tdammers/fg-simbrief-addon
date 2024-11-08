var urlencode = func(str) {
    var out = '';
    var c = '';
    var n = 0;
    for (var i = 0; i < size(str); i += 1) {
        n = str[i];
        if (string.isalnum(n)) {
            out = out ~ chr(n);
        }
        elsif (n == 32) {
            out = out ~ '+';
        }
        else {
            out = out ~ sprintf('%%%02x', n);
        }
    }
    return out;
};

var getFlightplan = nil;
var modifiedFlightplan = nil;

var download = func (username, onSuccess, onFailure=nil) {
    if (getprop('/sim/simbrief/downloading')) {
        logprint(4, "SimBrief download already active");
    }
    setprop('/sim/simbrief/downloading', 1);
    setprop('/sim/simbrief/text-status', 'downloading...');
    var filename = getprop('/sim/fg-home') ~ "/Export/simbrief.xml";
    var url = "https://www.simbrief.com/api/xml.fetcher.php?username=" ~ urlencode(username);
    if (onFailure == nil) {
        onFailure = func (r) {
            setprop('/sim/simbrief/text-status', sprintf('HTTP error (%s/%s)', r.status, r.reason));
            logprint(4, sprintf("SimBrief download from %s failed with HTTP status %s",
                url, r.status));
        }
    }

    http.save(url, filename)
        .done(func (r) {
                setprop('/sim/simbrief/text-status', 'parsing...');
                logprint(3, sprintf("SimBrief download from %s complete.", url));
                var errs = [];
                call(onSuccess, [filename], nil, {}, errs);
                if (size(errs) > 0) {
                    setprop('/sim/simbrief/text-status', 'errors, see log for details');
                    debug.printerror(errs);
                }
                else {
                    setprop('/sim/simbrief/text-status', 'all done!');
                }
            })
        .fail(onFailure)
        .always(func {
            setprop('/sim/simbrief/downloading', 0);
        });
};

var read = func (filename=nil) {
    if (filename == nil) {
        filename = getprop('/sim/fg-home') ~ "/Export/simbrief.xml";
    }
    var xml = io.readxml(filename);
    var ofpNode = xml.getChild('OFP');
    if (ofpNode == nil) {
        logprint(5, "Error loading SimBrief OFP");
        return nil;
    }
    else {
        return ofpNode;
    }
};

var toFlightplan = func (ofp, fp=nil) {
    # Options
    var importAirways = getprop('/sim/simbrief/options/import-airways') or 0;

    # get departure and destination
    var departureID = ofp.getNode('origin/icao_code').getValue();
    var departures = findAirportsByICAO(departureID);
    if (departures == nil or size(departures) == 0) {
        logprint(5, sprintf("Airport not found: %s", departureID));
        return nil;
    }

    var destinationID = ofp.getNode('destination/icao_code').getValue();
    var destinations = findAirportsByICAO(destinationID);
    if (destinations == nil or size(destinations) == 0) {
        logprint(5, sprintf("Airport not found: %s", destinationID));
        return nil;
    }

    # cruise parameters
    var initialAltitude = ofp.getNode('general/initial_altitude').getValue();
    var cruiseAltitude = initialAltitude;
    var seenTOC = 0;

    # collect enroute waypoints
    var wps = [];
    var ofpNavlog = ofp.getNode('navlog');
    var ofpFixes = ofpNavlog.getChildren('fix');
    var sidID = nil;
    var starID = nil;
    print("Importing fixes...");
    forindex (var fixIndex; ofpFixes) {
        var ofpFix = ofpFixes[fixIndex];
        if (ofpFix.getNode('is_sid_star').getValue() == 1) {
            if ((ofpFix.getValue('stage') == 'CLB') and
                (getprop('/sim/simbrief/options/import-departure') or 0) and
                (sidID == nil)) {
                sidID = ofpFix.getValue('via_airway');
            }
            elsif ((ofpFix.getValue('stage') == 'DSC') and
                (getprop('/sim/simbrief/options/import-arrival') or 0) and
                (starID == nil)) {
                starID = ofpFix.getValue('via_airway');
            }
            # skip: we only want enroute waypoints
            continue;
        }
        var ident = ofpFix.getNode('ident').getValue();
        if (ident == 'TOC' or ident == 'TOD') {
            # skip TOC and TOD: the FMS should deal with those dynamically
            if (ident == 'TOC') {
                seenTOC = 1;
            }
            continue;
        }
        # if no STAR was filed, simbrief may include the destination airport
        # as a fix, which will break the flightplan if we later attempt to
        # select a STAR, transition, or approach ourselves, so we need to skip
        # it.
        if (ident == destinationID and fixIndex == (size(ofpFixes) - 1)) {
            continue;
        }
        var altNode = ofpFix.getNode('altitude_feet');
        var alt = (altNode == nil) ? nil : altNode.getValue();
        var coords = geo.Coord.new();
        coords.set_latlon(
            ofpFix.getNode('pos_lat').getValue(),
            ofpFix.getNode('pos_long').getValue());
        logprint(2, sprintf("%s %f %f", ident, coords.lat(), coords.lon()));
        var wp = nil;
        var err = [];
        var airway = ofpFix.getValue('via_airway');
        if (importAirways and airway != nil) {
            wp = call(createViaTo, [airway, ident], nil, {}, err);
            if (size(err) > 0) {
                print(err);
                wp = nil;
            }
        }
        if (wp == nil or size(err) > 0) {
            wp = createWP(coords, ident);
        }
        append(wps, wp);
        if (seenTOC and alt == initialAltitude) {
            # this is the waypoint where we expect to reach initial cruise
            # altitude
            
            # reset 'seen TOC' flag to avoid setting alt restrictions on
            # subsequent waypoints
            seenTOC = 0;

            # we'll use an "at" restriction here: we don't want to climb any
            # higher, hence "above" would be wrong, and we want the VNAV to do
            # its best to reach the altitude before this point, so "below"
            # would also be wrong.

            # This doesn't work, and I don't know why.
            # wp.setAltitude(alt, 'at');
        }
        else if (alt > cruiseAltitude) {
            # this is a step climb target waypoint
            cruiseAltitude = alt;

            # This doesn't work, and I don't know why.
            # wp.setAltitude(alt, 'at');
        }
    }

    # we have everything we need; it's now safe-ish to overwrite or
    # create the actual flightplan


    if (fp == nil) {
        fp = createFlightplan();
    }
    fp.cleanPlan();
    fp.sid = nil;
    fp.sid_trans = nil;
    fp.star = nil;
    fp.star_trans = nil;
    fp.approach = nil;
    fp.approach_trans = nil;
    fp.departure = departures[0];
    foreach (var wp; wps) {
        fp.appendWP(wp);
    }
    fp.destination = destinations[0];
    if (getprop('/sim/simbrief/options/import-departure') or 0) {
        departureRunwayID = ofp.getNode('origin').getValue('plan_rwy');
        logprint(2, sprintf("Trying to select departure: %s / %s", sidID or 'NONE', departureRunwayID));
        if (!contains(departures[0].runways, departureRunwayID)) {
            logprint(4, sprintf("Runway not found: %s", departureRunwayID));
        }
        else {
            fp.departure_runway = departures[0].runways[departureRunwayID];
        }
        if (sidID != nil) {
            fp.sid = departures[0].getSid(sidID);
            if (fp.sid == nil)
                fp.sid = departures[0].getSid(sidID ~ '.' ~ departureRunwayID);
            if (fp.sid == nil) {
                logprint(4, sprintf("SID not found: %s", sidID));
            }
        }
    }
    if (getprop('/sim/simbrief/options/import-arrival') or 0) {
        destinationRunwayID = ofp.getNode('destination').getValue('plan_rwy');
        printf("Trying to select arrival: %s / %s", starID, destinationRunwayID);
        if (!contains(destinations[0].runways, destinationRunwayID)) {
            logprint(4, sprintf("Runway not found: %s", destinationRunwayID));
        }
        else {
            fp.destination_runway = destinations[0].runways[destinationRunwayID];
        }
        if (starID != nil) {
            fp.star = destinations[0].getStar(starID);
            if (fp.star == nil)
                fp.star = destinations[0].getStar(starID ~ '.' ~ destinationRunwayID);
            if (fp.star == nil) {
                logprint(4, sprintf("STAR not found: %s", starID));
            }
        }
    }
    return fp;
};

var importFOB = func (ofp) {
    var unit = ofp.getNode('params/units').getValue();
    var fuelFactor = ((unit == 'lbs') ? LB2KG : 1);

    # From here on, we'll do everything in kilograms (kg)
    var fob = ofp.getNode('fuel/plan_ramp').getValue() * fuelFactor;
    var unallocated = fob;
    var tankNodes = props.globals.getNode('/consumables/fuel').getChildren('tank');
    var strategy = getprop('sim/simbrief/options/fuel-strategy');
    logprint(3, sprintf("Allocating %1.1f kg (%1.1f lbs) of fuel", fob, fob * KG2LB));

    var numTanks = size(tankNodes);

    var allocate = func(tankNumber, maxAmount = nil) {
        var tankNode = tankNodes[tankNumber];
        var capacityNode = tankNode.getNode('capacity-m3');
        var densityNode = tankNode.getNode('density-kgpm3');
        if (tankNode == nil or capacityNode == nil or densityNode == nil) {
            logprint(3, sprintf("Tank #%i not installed", tankNumber));
            return;
        }
        var tankNameNode = tankNode.getNode('name');
        var tankName = sprintf("Tank #%i", tankNumber);
        if (tankNameNode != nil) {
            tankName = tankNameNode.getValue() or tankName;
        }
        var amount = unallocated;
        if (maxAmount != nil) {
            amount = math.min(amount, maxAmount);
        }
        var tankCapacity =
                (tankNode.getNode('capacity-m3').getValue() or 0) *
                (tankNode.getNode('density-kgpm3').getValue() or 0);
        if (tankCapacity < 10.0) {
            logprint(3, sprintf("Tank #%i too small, assuming fuel line or unused, will not change", tankNumber));
            amount = tankNode.getNode('level-kg').getValue() or 0;
        }
        else {
            amount = math.min(amount, tankCapacity);
            logprint(3, sprintf("Allocating %1.1f/%1.1f kg to %s", amount, unallocated, tankName));
            tankNode.getNode('level-kg').setValue(amount);
        }
        unallocated -= amount;
    }

    var allocatePair = func (tank1, tank2) {
        var cap1 = tankNodes[tank1].getValue('capacity-m3') or 1;
        var cap2 = tankNodes[tank2].getValue('capacity-m3') or 1;
        var cap = cap1 + cap2;
        var allocate1 = unallocated * cap1 / cap;
        var allocate2 = unallocated * cap2 / cap;
        allocate(tank1, allocate1);
        allocate(tank2, allocate2);
    }

    if (strategy == 'first-come-first-serve') {
        logprint(3, "Using 'first come, first serve' strategy");
        var i = 0;
        while (i < numTanks) {
            var tankNode = tankNodes[i];
            var tankName = tankNode.getValue('name') or 'unnamed';
            if (i >= numTanks - 1 or
                string.imatch(tankName, "*center*") or
                string.imatch(tankName, "*front*") or
                string.imatch(tankName, "*rear*")) {
                allocate(i);
                i = i + 1;
            }
            else {
                allocatePair(i, i + 1);
                i = i + 2;
            }
        }
    }
    elsif (strategy == 'balanced') {
        var totalFuel = unallocated;
        var totalCapacity = 0;
        foreach (var tankNode; tankNodes) {
            var capacity = tankNode.getValue('capacity-m3') or 0;
            totalCapacity = totalCapacity + capacity;
        }
        for (var i = 0; i < numTanks; i += 1) {
            var tankNode = tankNodes[i];
            var capacity = tankNode.getValue('capacity-m3') or 0;
            allocate(i, totalFuel * capacity / totalCapacity);
        }
    }
    else {
        logprint(5, sprintf("Invalid strategy '%s', please allocate fuel manually", strategy));
    }

    logprint(4, sprintf("Fuel not allocated: %1.1f kg", unallocated));
};

var importPayload = func (ofp) {
    var unit = ofp.getNode('params/units').getValue();
    var factor = ((unit == 'lbs') ? 1 : KG2LB);
    var weightNodes = [];
    var cargoWeightNodes = [];
    var paxWeightNodes = [];
    var payloadNode = props.globals.getNode('payload');
    if (payloadNode == nil) {
        # yasim puts weights in `/sim/weight[]`
        weightNodes = props.globals.getNode('/sim').getChildren('weight');
    }
    else {
        # jsbsim puts weights in `/payload/weight[]`
        weightNodes = payloadNode.getChildren('weight');
    }

    foreach (var node; weightNodes) {
        var nodeName = node.getValue('name') or '';

        logprint(3, sprintf("Checking weight node %s", nodeName));

        if (string.imatch(nodeName, "*passenger*") or
            string.imatch(nodeName, "*pax*") or
            string.imatch(nodeName, "*cabin*") or
            string.imatch(nodeName, "*class*") or
            string.imatch(nodeName, "*baggage*") or
            string.imatch(nodeName, "*seat*")) {
            append(paxWeightNodes, node);
        }
        elsif (string.imatch(nodeName, "*cargo*") or
               string.imatch(nodeName, "*payload*")) {
            append(cargoWeightNodes, node);
        }
    }

    if (size(paxWeightNodes) == 0 and size(cargoWeightNodes) == 0) {
        logprint(4, sprintf("Alas, this aircraft does not seem to use the standard weights system. Please configure payload manually."));
        return;
    }

    # Everything in lbs
    var cargoUnallocated = ofp.getNode('weights/cargo').getValue() * factor;
    var paxUnallocated = ofp.getNode('weights/payload').getValue() * factor - cargoUnallocated;

    var distribute = func (what, nodes, unallocated) {
        logprint(3, sprintf("Allocating %s: %1.1f lbs", what, unallocated));
        var totalF = 0;
        foreach (var node; nodes) {
            var f = node.getValue('max-lb') - node.getValue('min-lb');
            node.setValue('weight-lb', node.getValue('min-lb'));
            unallocated = unallocated - node.getValue('min-lb');
            totalF = totalF + f;
            logprint(3, sprintf("Allocating %1.1f/%1.1f lbs to %s", node.getValue('min-lb'), unallocated, node.getValue('name')));
        }
        logprint(3, sprintf("Remaining %s after minimum weights: %1.1f lbs", what, unallocated));
        var remaining = unallocated;
        if (remaining > 0) {
            foreach (var node; nodes) {
                var maxAdd = node.getValue('max-lb') - node.getValue('min-lb');
                var f = maxAdd / totalF;
                var toAdd = math.min(f * remaining, maxAdd, unallocated);
                node.setValue('weight-lb',
                    node.getValue('weight-lb') +
                    toAdd);
                unallocated = unallocated - toAdd;
                logprint(3, sprintf("Allocating %1.1f/%1.1f lbs to %s", toAdd, unallocated, node.getValue('name')));
            }
        }
        logprint(3, printf("Remaining unallocated %s: %1.1f lbs", what, unallocated));
        return unallocated;
    }

    if (size(paxWeightNodes) == 0) {
        logprint(4, "No passenger space found, forcing passengers into cargo hold");
        cargoUnallocated = cargoUnallocated + paxUnallocated;
        paxUnallocated = 0;
    }
    cargoUnallocated = distribute("cargo", cargoWeightNodes, cargoUnallocated);
    paxUnallocated = distribute("passengers", paxWeightNodes, paxUnallocated + cargoUnallocated);
};

var importPerfInit = func (ofp) {
    # climb profile: kts-below-FL100/kts-above-FL100/mach
    var climbProfile = split('/', ofp.getNode('general/climb_profile').getValue() ~ '////');
    # descent profile: mach/kts-above-FL100/kts-below-FL100
    var descentProfile = split('/', ofp.getNode('general/descent_profile').getValue());
    var cruiseMach = ofp.getNode('general/cruise_mach').getValue();
    var airline = ofp.getNode('general/icao_airline').getValue();
    var flightNumber = ofp.getNode('general/flight_number').getValue();
    var callsign = (airline == nil) ? flightNumber : (airline ~ flightNumber);
    var cruiseAlt = ofp.getNode('general/initial_altitude').getValue();

    
    setprop("/sim/multiplay/callsign", callsign);
    setprop("/autopilot/route-manager/cruise/altitude-ft", cruiseAlt);

    if (props.globals.getNode("/controls/flight/speed-schedule") != nil) {
        setprop("/controls/flight/speed-schedule/climb-below-10k", climbProfile[0]);
        setprop("/controls/flight/speed-schedule/climb-kts", climbProfile[1]);
        setprop("/controls/flight/speed-schedule/climb-mach", climbProfile[2] / 100);
        setprop("/controls/flight/speed-schedule/cruise-mach", cruiseMach);
        setprop("/controls/flight/speed-schedule/descent-mach", descentProfile[0] / 100);
        setprop("/controls/flight/speed-schedule/descent-kts", descentProfile[1]);
        setprop("/controls/flight/speed-schedule/descent-below-10k", descentProfile[2]);
    }
};

var aloftTimer = nil;
var aloftPoints = [];

var setAloftWinds = func (aloftPoint) {
    forindex (var i; aloftPoint.layers) {
        var node = props.globals.getNode("/environment/config/aloft/entry[" ~ i ~ "]");
        node.getChild('elevation-ft').setValue(aloftPoint.layers[i].alt);
        node.getChild('wind-from-heading-deg').setValue(aloftPoint.layers[i].dir);
        node.getChild('wind-speed-kt').setValue(aloftPoint.layers[i].spd);
        # node.getChild('temperature-degc').setValue(aloftPoint.layers[i].temp);
        logprint(
            2,
            sprintf("ALOFT AFTER %5i': %03i/%i (slp = %02.2f)",
                node.getChild('elevation-ft').getValue(),
                node.getChild('wind-from-heading-deg').getValue(),
                node.getChild('wind-speed-kt').getValue(),
                node.getChild('pressure-sea-level-inhg').getValue()));
    }
};

var interpolate = func (f, a, b) {
    return a + math.min(1.0, math.max(-1.0, f)) * (b - a);
};

var interpolateDegrees = func (f, a, b) {
    return geo.normdeg(a + geo.normdeg180(b - a) * f);
};

var interpolateComponentWise = func (f, ipf, a, b) {
    var s = math.min(size(a), size(b));
    var result = [];
    for (var i = 0; i < s; i = i+1) {
        append(result, ipf(f, a[i], b[i]));
    }
    return result;
};

var interpolateLayers = func (f, a, b) {
    if (b == nil) return a;
    if (a == nil) return b;
    return {
        alt: interpolate(f, a.alt, b.alt),
        spd: interpolate(f, a.spd, b.spd),
        temp: interpolate(f, a.temp, b.temp),
        dir: interpolateDegrees(f, a.dir, b.dir),
    };
};

var interpolateAloftPoints = func (f, a, b) {
    if (b == nil) return a;
    if (a == nil) return b;
    return {
        layers: interpolateComponentWise(f, interpolateLayers, a.layers, b.layers),
    };
};

var updateAloft = func () {
    # printf("updateAloft()");
    if (getprop("/environment/params/metar-updates-winds-aloft")) {
        logprint(3, "Weather configuration invalid for SimBrief weather updater, stopping");
        stopAloftUpdater();
        return;
    }
    var pos = geo.aircraft_position();
    foreach (var p; aloftPoints) {
        p.dist = pos.distance_to(p.coord);
    }
    var sorted = sort(aloftPoints, func (a, b) { return (a.dist - b.dist); });
    var pointA = sorted[0];
    var pointB = sorted[1];
    var f = (pointB.dist < 0.1) ? 0 : (pointB.dist / (pointA.dist + pointB.dist));
    # foreach (var s; sorted) {
    #     printf(s.dist);
    # }
    # debug.dump(f, pointA, pointB);
    var aloftPoint = interpolateAloftPoints(f, pointA, pointB);
    # printf("Aloft wind interpolation: %f between %s and %s",
    #     f, pointA.name, pointB.name);
    # debug.dump(aloftPoint.layers);
    setAloftWinds(aloftPoint);
};

var startAloftUpdater = func () {
    setprop("/environment/params/metar-updates-winds-aloft", 0);
    if (aloftTimer == nil) {
        aloftTimer = maketimer(10, updateAloft);
        aloftTimer.simulatedTime = 1;
    }
    if (aloftTimer.isRunning) return;
    aloftTimer.start();
    setprop('/sim/simbrief/aloft-updater-status', 'running');
};

var stopAloftUpdater = func () {
    if (aloftTimer != nil) {
        aloftTimer.stop();
        setprop('/sim/simbrief/aloft-updater-status', 'stopped');
    }
};

var importWindsAloft = func (ofp) {
    # # disable default winds and set winds-aloft mode
    setprop("/environment/params/metar-updates-winds-aloft", 0);

    # now go through the flightplan waypoints and create a wind interpolation point for each of them.
    var ofpNavlog = ofp.getNode('navlog');
    var ofpFixes = ofpNavlog.getChildren('fix');
    foreach (var ofpFix; ofpFixes) {
        var lat = ofpFix.getNode('pos_lat').getValue();
        var lon = ofpFix.getNode('pos_long').getValue();
        var layers = [];
        var uneven = 0;
        foreach (var ofpWindLayer; ofpFix.getNode('wind_data').getChildren('level')) {
            var dir = ofpWindLayer.getNode('wind_dir').getValue();
            var spd = ofpWindLayer.getNode('wind_spd').getValue();
            var alt = ofpWindLayer.getNode('altitude').getValue();
            var temp = ofpWindLayer.getNode('oat').getValue();
            # pick up every other layer: simbrief reports 10 layers starting
            # at sea level, but we can only use 5, and we don't need sea level
            # (as that comes from METAR)
            if (uneven) {
                append(layers, { alt: alt, dir: dir, spd: spd, temp: temp });
            }
            uneven = !uneven;
        }
        var aloftPos = geo.Coord.new();
        aloftPos.set_latlon(lat, lon);

        var aloftPoint = { coord: aloftPos, dist: 0.0, layers: layers, name: ofpFix.getNode('ident').getValue() };
        append(aloftPoints, aloftPoint);
    }
    startAloftUpdater();
};

var loadFP = func () {
    if (getFlightplan == nil) {
        if (typeof(globals['getFlightplan']) == 'func') {
            logprint(3, 'Found exiting getFlightplan function');
            getFlightplan = globals['getFlightplan'];
        }
        else {
            logprint(3, 'Using default getFlightplan function');
            getFlightplan = func (index=0) {
                if (index == 0) {
                    return flightplan();
                }
                else {
                    if (modifiedFlightplan == nil)
                        modifiedFlightplan = createFlightplan();
                    return modifiedFlightplan;
                }
            }
        }
    }

    if (contains(globals, 'commitFlightplan') and
            typeof(globals['commitFlightplan']) == 'func') {
        logprint(3, 'Found existing commitFlightplan function');
        commitFlightplan = globals['commitFlightplan'];
    }
    else {
        logprint(3, 'Using default commitFlightplan function');
        globals['commitFlightplan'] = func () {
            modifiedFlightplan.activate();
            fgcommand("activate-flightplan", {active: 1});
            modifiedFlightplan = nil;
            setprop("/fms/flightplan-modifications", 1);
            setprop("/autopilot/route-manager/active", 1);
        };
    }

    var username = getprop('/sim/simbrief/username');
    if (username == nil or username == '') {
        print("Username not set");
        return;
    }

    download(username, func (filename) {
        var ofpNode = read(filename);
        if (ofpNode == nil) {
            print("Error loading simbrief XML file");
            return;
        }

        if (getprop('/sim/simbrief/options/import-fp') or 0) {
            var modifyableFlightplan = getFlightplan(1);
            var fp = toFlightplan(ofpNode, modifyableFlightplan);
            if (fp == nil) {
                print("Error parsing flight plan");
            }
            else {
                if (getprop('/sim/simbrief/options/autocommit') or 0) {
                    commitFlightplan();
                }
            }
        }
        if (getprop('/sim/simbrief/options/import-fob') or 0) {
            importFOB(ofpNode);
        }
        if (getprop('/sim/simbrief/options/import-payload') or 0) {
            importPayload(ofpNode);
        }
        if (getprop('/sim/simbrief/options/import-perfinit') or 0) {
            importPerfInit(ofpNode);
        }
        if (getprop('/sim/simbrief/options/import-winds-aloft') or 0) {
            importWindsAloft(ofpNode);
        }
    });
};

var findMenuNode = func (create=0) {
    var equipmentMenuNode = props.globals.getNode('/sim/menubar/default/menu[5]');
    foreach (var item; equipmentMenuNode.getChildren('item')) {
        if (item.getValue('name') == 'addon-simbrief') {
            return item;
        }
    }
    if (create) {
        return equipmentMenuNode.addChild('item');
    }
    else {
        return nil;
    }
};

var main = func(addon) {
    if (globals['simbrief'] != nil) {
        logprint(3, "SimBrief importer already present, not activating add-on");
    }
    elsif (props.globals.getNode('/FMGC/simbrief-username') != nil) {
        logprint(3, "A320 SimBrief import feature detected, not activating add-on");
    }
    else {
        logprint(3, "Loading SimBrief importer");
        globals['simbrief'] = {
            'loadFP': loadFP,
            'startAloftUpdater': startAloftUpdater,
            'stopAloftUpdater': stopAloftUpdater,
        };
        var myMenuNode = findMenuNode(1);
        myMenuNode.setValues({
            enabled: 'true',
            name: 'addon-simbrief',
            label: 'SimBrief Import',
            binding: {
                'command': 'dialog-show',
                'dialog-name': 'addon-simbrief-dialog',
            },
        });
        fgcommand('reinit', {'subsystem': 'gui'});
    }
};
