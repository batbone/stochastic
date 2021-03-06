# We are assuming the unit time is one day.

# module SIR
using Luxor
##
(@isdefined SunHasSet) || begin include("../common/startup.jl") ; println("Using backup startup.jl.") end
using Random, Distributions, DataStructures, Lazy, MLStyle, UUIDs, IterTools, Dates
using Gadfly
import Cairo, Fontconfig
using Colors
using ForceImport
@force using Luxor
using MLStyle.AbstractPatterns: literal
include("../common/event.jl")
##
@enum InfectionStatus Healthy = 1 Recovered RecoveredRemission Sick Dead 
MLStyle.is_enum(::InfectionStatus) = true
# tell the compiler how to match it
MLStyle.pattern_uncall(e::InfectionStatus, _, _, _, _) = literal(e)
###

mutable struct Place{T} 
    name::String
    width::Float64
    height::Float64
    plotPos::NamedTuple{(:x, :y),Tuple{Float64,Float64}}
    people::Set{T}
    smallGridMode::Float64 # zero to disable
    function Place(; name, width, height, people=Set(), plotPos, smallGridMode=0.0)
        new{Person}(name, width, height, plotPos, people, smallGridMode)
    end
end
mutable struct Marketplace{R,E}
    place::Place
    # μg::Float64
    enterRd::R
    exitRd::E
    function Marketplace{R,E}(place, enterRd::R, exitRd::E) where {R,E}
        new{R,E}(place, enterRd, exitRd)
    end
end
function Marketplace(; place, 
    # Realistic times will not be noticeable in our timeframes. So let's think of these as hotels. not markets.
    μg::Number=(1 / 40), ag::Number=(0.5), bg::Number=(20) 
    # μg::Number=(1 / 4), ag::Number=(0.5 / 24), bg::Number=(4 / 24) 
    )
    Marketplace{Exponential{Float64},Uniform{Float64}}(place, Exponential(inv(μg)), Uniform(ag, bg))
end
mutable struct Workplace
    place::Place
    startTime::Float64
    endTime::Float64
    eP::Float64 # The proportion of total population working there
    function Workplace(; place, startTime, endTime, eP)
        new(place, startTime, endTime, eP)
    end
end
@inline function restDuration(workplace::Workplace)
    res = (1 - workplace.endTime) + workplace.startTime
    # works if the endTime is after midnight, too
    if workplace.endTime < workplace.startTime
        res -= 1
    end
    return res
end

mutable struct Person
    id::Int
    pos::NamedTuple{(:x, :y),Tuple{Float64,Float64}}
    status::InfectionStatus
    currentPlace::Union{Place,Nothing}
    workplace::Union{Workplace,Nothing}
    isIsolated::Bool
    sickEvent::Union{Int,Nothing}
    moveEvents::Array{Int}
    function Person(; id=-1, pos=(x = 0., y = 0.), status=Healthy, currentPlace, workplace=nothing, isIsolated=false, 
        sickEvent=nothing
        , moveEvents=[]
        )
        me = new(id, pos, status, currentPlace, workplace, isIsolated, 
        sickEvent
        , moveEvents
        )
        push!(currentPlace.people, me)
        me
    end
end
###
function colorPerson(person::Person)
    colorStatus(getStatus(person))
end
# function statusFromString_(status::String)
#     eval(Meta.parse(status))
# end
# @defonce const statusFromString = memoize(statusFromString_)
function colorStatus(status::InfectionStatus)
    @match status  begin
        Sick => RGB(1, 0, 0) # :red    
        Healthy => RGB(0, 1, 0) # :green
        Dead => RGB(0, 0, 0) # :black
        RecoveredRemission => RGB(1, 0.7, 0) # RGB(1, 1, 0) # :yellow
        Recovered => RGB(0, 1, 1) # :blue
    end
end
function defaultNextConclusion()
    rand(Uniform(7, 20))
end
function defaultHasDiedλ(p_recovery)
    function hasDied()
        if rand() <= p_recovery 
            return false
        else
            return true
        end
    end
    return hasDied
end
function defaultNextCompleteRecovery()
    rand(Uniform(5, 15))
end

mutable struct CoronaModel{F1,F2,F3,F4,N <: Number}
    name::String
    discrete_opt::N
    centralPlace::Place
    marketplaces::Array{Marketplace}
    workplaces::Array{Workplace}
    isolationProbability::Float64
    μ::Float64
    pq::MutableBinaryMinHeap{SEvent}
    nextConclusion::F1
    hasDied::F2
    nextCompleteRecovery::F3
    nextSickness::F4
    function CoronaModel{F1,F2,F3,F4,N}(name, discrete_opt::N, centralPlace, marketplaces, workplaces, isolationProbability, μ, pq, nextConclusion::F1, hasDied::F2, nextCompleteRecovery::F3, nextSickness::F4) where {F1,F2,F3,F4,N}
        me = new(name, discrete_opt, centralPlace, marketplaces, workplaces, isolationProbability, μ, pq, nextConclusion, hasDied, nextCompleteRecovery, nextSickness)
        # me.nextSickness = (p::Person) -> nextSickness(me, p)
        me
    end
end
function CoronaModel(; name="untitled", discrete_opt::N=(1.0), centralPlace=nothing,
    marketplaces=[], workplaces=[], smallGridMode=0.0, isolationProbability=0.0, μ=1.0, nextSickness::F4,
    pq=MutableBinaryMinHeap{SEvent}(),
    nextConclusion::F1=defaultNextConclusion,
    hasDied::F2=defaultHasDiedλ(0.9),
    nextCompleteRecovery::F3=defaultNextCompleteRecovery
    ) where {F1,F2,F3,F4,N}

    if isnothing(centralPlace)
        centralPlace = Place(; name="Central", width=580, height=500, plotPos=(x = 10, y = 10))
    end
    centralPlace.smallGridMode = smallGridMode
    CoronaModel{F1,F2,F3,F4,N}(name, discrete_opt, centralPlace, marketplaces, workplaces, isolationProbability, μ, pq, nextConclusion, hasDied, nextCompleteRecovery, nextSickness)
end

function getStatus(person::Person)
    person.status# []
end
function getPos(person::Person)
    person.pos# []
end
function getPlace(person::Person)
    person.currentPlace# []
end
function countStatus(people::AbstractArray{Person}, status::InfectionStatus)
    count(people) do p p.status == status end
end
function countStatuses(people)
    res::Dict{InfectionStatus,Int64} = Dict()
    for status in instances(InfectionStatus)
        push!(res, status => countStatus(people, status))
    end
    res
end
function insertPeople(dt, t, people, visualize)
    counts = countStatuses(people)
    if visualize
        for status in instances(InfectionStatus)
            push!(dt, (t, counts[status], string(status)))    
        end
    end
    counts
end
function event2aniTime(tNow)
    # With the %f format specifier, the "2" is treated as the minimum number of characters altogether, not the number of digits before the decimal dot. 
    mins = floor(tNow / 60)
    secs = tNow - 60 * mins
    @sprintf "%02d:%012.9f" mins secs 
end
function time2day(time::Number)
    days = floor(Int, time)
    rem = time - days
    rem = floor(rem*3600*24)
    hours = floor(rem / 3600)
    rem -= hours*3600
    mins = floor(rem/60)
    # secs = rem - 60 * mins
    @sprintf "#%03d %02d:%02d" days hours mins 
end
@copycode alertStatus begin
    sv1("$tNow: Person #$(person.id) is $(getStatus(person))")
end
@copycode nodead begin
    if person.status == Dead
        return
    end
end
macro injectModel(name)
    quote
        function $(esc(name))(args...; kwargs...)
            $(esc(:(model.$name)))($(esc(:model)), args... ; kwargs...)
        end
    end
end
function isTracked(person::Person)
    person.id % 23 == 0
end
isolationColor = colorant"purple"
function runModel(; model::CoronaModel, n::Int=10, simDuration::Number, visualize::Bool=true, sleep::Bool=true, framerate::Int=30, daysInSec::Number=1, scaleFactor::Number=3, initialPeople::Union{AbstractArray{Person},Nothing,Function}=nothing, marketRemembersPos=true, tracking=false, visTS::Bool=true)
    startTime = time()
    ###
    if isa(initialPeople, Function)
        initialPeople = initialPeople(model)
    end
    if ! isnothing(initialPeople)
        n = length(initialPeople)
    end
    ###
    @injectModel nextSickness
    discrete_opt = model.discrete_opt # Set to 0 to get the true simulation, increase for speed
    internalVisualize::Bool = visualize
    initCompleted::Bool = false
    visualize::Bool = false
    removedEvents = BitSet()
    function pushEvent(callback::Function, time::Float64)
        return push!(model.pq, SEvent(callback, time)) # returns handle to event
    end
    runDesc = "$(model.name), n=$n, μ=$(model.μ), discrete_opt=$(discrete_opt), isolationP=$(model.isolationProbability), DiS=$daysInSec, RM=$marketRemembersPos"
    runID = @> "$runDesc - $(Dates.now())" replace(r"/+" => "÷") # $(uuid4())

    plotdir = "$(pwd())/makiePlots/$(runID)"
    mkpath(plotdir)
    @labeled plotdir
    ###
    log_io = open("$plotdir/log.txt", "w")
    function sv_g(level::Int64, str)
        if serverVerbosity >= level
            println(str)
            println(log_io, str)
        end
    end
    sv0(str) = sv_g(0, str)
    sv1(str) = sv_g(1, str)
    ###
    frameCounter = 0
    lastTime = 0
    function drawPlace(place::Place)
        # be sure to output images with even width and height, or encoding them will need padding
        gsave()
        padTop = 16

        translate(place.plotPos.x, place.plotPos.y)
        sethue("black")
        text(place.name, 0, padTop - 6)
        translate(0, padTop)
        setline(6)
        rect(0, 0, place.width, place.height, :stroke)
        setline(1)
        rect(0, 0, place.width, place.height, :clip)
        if place.smallGridMode > 0
            gsave()
            sethue(RGB(0, 16 / 255, 110 / 255))
            setdash("dotdotdotdashed")
            for i in 0:place.smallGridMode:(place.width + place.smallGridMode), j in 0:place.smallGridMode:(place.height + place.smallGridMode)
                rect(i, j, place.smallGridMode, place.smallGridMode, :stroke)
            end
            grestore()
        end
        for person::Person in place.people 
            if tracking && isTracked(person)
                continue
            end
            setopacity(0.65)
            sethue(colorPerson(person))
            circle(person.pos.x, person.pos.y, 2.3, :fill)

            if person.isIsolated
                sethue(isolationColor)
                setline(4.5)
            else
                sethue("white")
                setline(3)
            end
            setopacity(1.0)
            circle(person.pos.x, person.pos.y, 2.8, :stroke) 
        end
        if tracking
            for person::Person in place.people
                # OVERLAY PHASE
                if tracking && isTracked(person) # for debugging purposes
                    setopacity(1.0)
                    # setmode("overlay") # didn't work well
                    if person.isIsolated
                        my_color = isolationColor
                    else
                        my_color = colorPerson(person)
                    end
                    my_foreground = @match person.status begin
                        Sick || RecoveredRemission || Dead=> RGB(1, 1, 1) # :red    
                        Healthy || Recovered => RGB(0, 0, 0) # :green
                    end

                    settext("<span font='20' background ='#$(hex(my_color))' foreground='#$(hex(my_foreground))'><b>$(person.id)</b></span>", Point(person.pos...) ; markup=true, halign="center", valign="center")

                    @comment begin
                        # @bitrot might need gsave, grestore
                        sethue(colorPerson(person))
                        # settext("<span font='18' ><b>$(person.id)</b></span>", Point(person.pos...) ; markup=true, halign="center", valign="center")

                        setline(3)
                        fontsize(22)
                        textoutlines("#$(person.id)", Point(person.pos...), :path, valign=:center, halign=:center)
                        fillpreserve()
                        if person.isIsolated
                            sethue(isolationColor)
                        else
                            sethue("gold")
                        end
                        strokepath()
                    end
                end
                @comment if place.smallGridMode > 0 && rand() <= 0.1 # for debugging purposes
                    gsave()
                    setopacity(1.0)
                    sethue("blue")
                    fontsize(6)
                    textcentered(string(getSMG(person)), person.pos...)
                    grestore()
                end
            end
        end
        grestore()
    end
    function makieSave(tNow)
        frames = floor(Int, ((tNow - lastTime) / daysInSec) / (1 / framerate))
        if frameCounter == 0
            frames = 1 # because we need to copy the previous keyframe, we need a bootstrap method
        end
        if frames <= 0
            return
        end
        lastTime = tNow

        # use previous keyframe
        dest = "$plotdir/all/$(@sprintf "%06d" frameCounter).png"
        mkpath(dirname(dest))
        for i in 2:frames
            frameCounter += 1
            destCopy = "$plotdir/all/$(@sprintf "%06d" frameCounter).png"
        
            cmd = `cp  $dest $destCopy`
            run(cmd, wait=false)
        end

        frameCounter += 1
        dest = "$plotdir/all/$(@sprintf "%06d" frameCounter).png"
 
        dw = 600
        dh = 600
        Drawing(dw * scaleFactor, dh * scaleFactor, dest) # HARDCODED
        scale(scaleFactor)
        background("white")
        sethue("black")
        titlePos = (x = dw / 2, y = 15)
        settext("<span font='12' ><tt>$runDesc</tt></span>", Point(titlePos.x, titlePos.y) ; markup=true, halign="center", valign="center")
        textcentered("Time of Last Snapshot = $tNow ($(time2day(tNow)))", titlePos.x, titlePos.y * 2 + 10)
        translate(0, titlePos.y * 3 + 0)

        for place in Iterators.flatten(((model.centralPlace,), model.workplaces, model.marketplaces))
            if !(place isa Place)
                place = place.place
            end
            drawPlace(place)
        end

        finish()
        sv0("Key frame saved: $dest")

        # preview() # didn't work here, idk why
        # error("hi")
    end
    function setStatus(tNow, person::Person, status::InfectionStatus)
        person.status = status
        if status == Sick
            if model.isolationProbability > 0.0 && initCompleted
                if rand() <= model.isolationProbability
                    person.isIsolated = true
                end
            end
        else
            person.isIsolated = false
        end
        if initCompleted
            @alertStatus
            if ! person.isIsolated
                recalcSickness(tNow, person.currentPlace)
            end
        end
    end
    function setPos(tNow, person::Person, pos)
        person.pos = pos
        recalcSickness(tNow, person.currentPlace)
    end
    function randomizePos(tNow, person::Person)
        setPos(tNow, person, (x = rand(Uniform(0, getPlace(person).width)), y = rand(Uniform(0, getPlace(person).height))))
        return person
    end
    function cleanupEvents(handles::AbstractArray{Int})
        for handle in handles 
            cleanupEvents(handle)
        end
    end
    function cleanupEvents(handle::Int)
        if handle ∉ removedEvents
            delete!(model.pq, handle)
            push!(removedEvents, handle)
        end
    end
    function cleanupEvents(handle::Nothing) end
    lastRecalcTime = 0
    function recalcSickness(tNow, place::Place)
        if ! initCompleted
            return
        end
        if discrete_opt > 0
            if ! (isempty(model.pq)) 
                nEvent, useless = top_with_handle(model.pq) # first(model.pq) didn't work
                if nEvent.time - lastRecalcTime < discrete_opt
                    return # we can take the hit
                end
            end
            lastRecalcTime = tNow
        end
        for person in place.people
            cleanupEvents(person.sickEvent)
            genSickEvent(tNow, person)
        end
    end
    function infect(tNow, person::Person)
        setStatus(tNow, person, Sick)
        pushEvent(tNow + model.nextConclusion()) do tNow
            if model.hasDied()
                setStatus(tNow, person, Dead)
            else
                setStatus(tNow, person, RecoveredRemission)
                pushEvent(tNow + model.nextCompleteRecovery()) do tNow
                    setStatus(tNow, person, Recovered)
                end
            end
        end
    end
    function genSickEvent(tNow, person::Person)
        tillNext = nextSickness(person)
        if Inf > tillNext >= 0
            sickEvent = pushEvent(tNow + tillNext) do tNow
                infect(tNow, person)
            end
            person.sickEvent = sickEvent
        end
        return person
    end
    firstSickPerson = true # ensures we'll have at least one sick person
    function randomizeSickness(person::Person)
        if firstSickPerson || rand() < 0.1
            firstSickPerson = false
            infect(0, person)
            sv1("Person #$(person.id) randomized to sickness.")
        end
        return person
    end
    rememberedPositions::Dict{Any,Any} = Dict()
    function swapPlaces(tNow, person::Person, newPlace::Place ; rememberOldPos=false, rememberNewPos=false)
        @assert person.status ≠ Dead "Deadmen don't move!"
        oldPlace = person.currentPlace
        sv1("Person #$(person.id) going from '$(oldPlace.name)' to '$(newPlace.name)'.")
        cleanupEvents(person.moveEvents)
        person.currentPlace = newPlace
        delete!(oldPlace.people, person)
        push!(newPlace.people, person)
        recalcSickness(tNow, oldPlace) # Note that this happens automatically for newPlace because of setPos
        if rememberOldPos
            rememberedPositions[person, oldPlace] = person.pos
        end
        if rememberNewPos
            newPos = get(rememberedPositions, (person, newPlace), nothing)
            if isnothing(newPos)
                sv0("!!! Asked to remember position for (person: #$(person.id), place: $(place.name)), but no memory found. Randomizing new position.")
                randomizePos(tNow, person)
            else
                setPos(tNow, person, newPos)
            end
        else
            randomizePos(tNow, person)
        end
        return oldPlace
    end
    function maybeGoToMarket(tNow, market::Marketplace, person::Person)
        @nodead
        tNext = tNow + rand(market.enterRd)
        moveEvent = pushEvent(tNext) do tNow # Enter the market
            @nodead
            oldPlace = swapPlaces(tNow, person, market.place; rememberOldPos=marketRemembersPos)
            tNext = tNow + rand(market.exitRd)
            moveEvent = pushEvent(tNext) do tNow # Go back to where they came from
                @nodead
                swapPlaces(tNow, person, oldPlace ; rememberNewPos=marketRemembersPos)
                genMarketEvents(tNow, person)
            end
            push!(person.moveEvents, moveEvent)
        end
        push!(person.moveEvents, moveEvent)
    end
    function genMarketEvents(tNow, person::Person)
        for market in model.marketplaces
            maybeGoToMarket(tNow, market, person)
        end
    end
    ###
    if isnothing(initialPeople)
        people = [@>> Person(; id=i, currentPlace=model.centralPlace) randomizePos(0) randomizeSickness() for i in 1:n]
    else
        @assert length(initialPeople) == n "initialPeople should have match the supplied population number 'n'!" # Now useless, as I set n to length of initialPeople.
        people = initialPeople
        for person in people
            if isnothing(person.currentPlace)
                person.currentPlace = model.centralPlace
            end
            if person.status == Sick
                infect(0, person)
            end
        end
    end
    shuffle!(people) # so that people are assigned their workplaces randomly 
    ###
    for person in people
        genMarketEvents(0, person)
    end
    ###
    function scheduleWork(tNow, person::Person)
        @nodead
        tNext = tNow
        dayT = tNow - floor(tNow)
        if dayT <= person.workplace.startTime
            tNext += person.workplace.startTime - dayT
        else
            tNext += person.workplace.startTime + (1 - dayT)
        end
        pushEvent(tNext) do tNow # go to work
            @nodead
            oldPlace = swapPlaces(tNow, person, person.workplace.place; rememberOldPos=marketRemembersPos) # @WONTFIX Use another param for this (actually don't, as you'll need markets to remember pos for you since you might go market->work->central)
            tNext = tNow + (1 - restDuration(person.workplace))
            moveEvent = pushEvent(tNext) do tNow # Go back to Central
                @nodead
                swapPlaces(tNow, person, model.centralPlace ; rememberNewPos=marketRemembersPos)
                genMarketEvents(tNow, person)
                scheduleWork(tNow, person)
            end
        end
    end

    employedN = 0
    for work in model.workplaces
        num = floor(Int, work.eP * n)
        eS = (employedN + 1)
        for person::Person in people[eS:(eS + num - 1)]
            person.workplace = work
            scheduleWork(0, person)
        end
        employedN += num
    end
    sv0("#$employedN people are employed, being $(employedN*100/n)% of the population.")
    ###
    initCompleted = true
    recalcSickness(0, model.centralPlace)

    dt::Union{DataFrame,Nothing} = nothing
    if internalVisualize
        visualize = true
        makieSave(0)
    end
    if visTS
        dt = DataFrame(Time=Float64[], Number=Int64[], Status=String[])
    end
    runi(`brishzq.zsh pbcopy $plotdir/`) # Alt: Use helpers.zsh 

    cEvent = nothing
    try
        while ! (isempty(model.pq))
            cEvent, h = top_with_handle(model.pq)
            cleanupEvents(h)
            if cEvent.time > simDuration
                sv0("Simulation has exceeded authorized duration. Concluding.")
                break
            end
            sv1("-> receiving event at $(cEvent.time) ($(time2day(cEvent.time)))")
            cEvent.callback(cEvent.time)

            if visualize
                makieSave(cEvent.time)
            end 

            counts = insertPeople(dt, cEvent.time, people, visTS)
            if all(counts[s] == 0 for s in (Sick, RecoveredRemission))
                sv0("Simulation has reached equilibrium.")
                break
            end
        end
    finally
        @assert (! isnothing(cEvent)) "Simulation has not run any events."
        sv0("Simulation ended at day $(cEvent.time) and took $(time() - startTime).")
        close(log_io) # flushes as well
    end
    if visTS
        plotTimeseries(dt, "$plotdir/timeseries.png")
    else
        bello()
    end
    return people, dt
    # return model.pq  # causes stackoverflow on VSCode displaying it
end
function plotTimeseries(dt::DataFrame, dest)
    dest_dir = dirname(dest)
    mkpath(dest_dir)
    plot(dt, x=:Time, y=:Number, color=:Status,
        Geom.line(),
        Scale.color_discrete_manual([colorStatus(status) for status in instances(InfectionStatus)]...),
        Theme(
            key_label_font_size=29pt,
            key_title_font_size=36pt,
            major_label_font_size=29pt,
            minor_label_font_size=28pt,
            line_width=2pt,
            background_color="white",
            # alphas = [1],
        )
    ) |> PNG(dest, 26cm, 18cm, dpi=150)


    ###
    begin
        runi(`brishzq.zsh awaysh brishz-all source $(ENV["HOME"])/Base/_Code/uni/stochastic/makiePlots/helpers.zsh`, wait=true) # We have to free the sending brish or it'll deadlock
        sleep(1.0) # to make sure things have loaded succesfully

        # sout was useless
        # runi(`brishzq.zsh serr ani-ts $dest_dir`, wait=false)
        runi(`brishzq.zsh serr ani-ts $dest_dir`, wait=true)
        runi(`brishzq.zsh makie-clean`, wait=true)
    end

    bella()
    ###
end

firstbell()
## Executors
serverVerbosity = 0
function nextSicknessExp(model::CoronaModel, person::Person)::Float64
    if getStatus(person) == Healthy
        rand(Exponential(inv(model.μ)))
    else
        -1.0
    end
end
function execModel(; visualize=true, n=10^3, model, simDuration=1000, discrete_opt=nothing, kwargs...)

    if ! isnothing(discrete_opt)
        @warn "Setting discrete_opt from execModel is a back-compat API."
        model.discrete_opt = discrete_opt
    end

    took = @elapsed ps, dt = runModel(; model=model, simDuration, n=n, visualize=visualize, kwargs...)
    println("Took $(took) (with plotTimeseries)")
    global lastPeople, lastDt = ps, dt

    count_healthy = count(ps) do p p.status == Healthy end
    if count_healthy > 0
        println("!!! There are still $count_healthy healthy people left in the simulation!")
    end
    if (count_healthy + length(collect(nothing for p in ps if (getStatus(p) == Recovered || getStatus(p) == Dead)))) != length(ps) 
        @warn "Total recovered, healthy, and dead people don't match total people. Either the simulation has been ended prematurely, or there is a bug."
    end
    return nothing
end
## Spaces
function gg1(; gw=20, gh=40, gaps=[(i, j) for i in 20:22 for j in 1:gw])
    function genp_grid_hgap(model::CoronaModel)
        cc = 0
        function get_cc() 
            cc += 1
            return cc
        end
        n = gw * gh - length(gaps)

        cp = model.centralPlace
        ip = [Person(; id=(get_cc()), currentPlace=cp, 
                    pos=(x = j * ((cp.width - 20) / gw),
                        y = i * ((cp.height - 20) / gh)),
                    status=(if i in 1:2
            Sick
        else
            Healthy
        end)
                ) 
            for i in 1:gh for j in 1:gw if !((i, j) in gaps)]
    end
    genp_grid_hgap
end
gp_H_dV = gg1(; gaps=vcat([(i, j) for i in 20:22 for j in 1:100], [(i, j) for i in 23:100 for j in 9:11]))
## markets
function withMW(model_fn::Function, args... ; oneMarketMode=false, noWork=false, kwargs...)
    vpad = 27 # should cover the titles, too
    hpad = 20
    centralPlace = Place(; name="Central", width=310, height=400, plotPos=(x = 10, y = 10))

    m1 = Marketplace(; 
        place=Place(; name="Hotel α",
        width=100,
        height=70,
        plotPos=(x = (centralPlace.plotPos.x + centralPlace.width + hpad),
            y = centralPlace.plotPos.y) 
    ))
    m2 = Marketplace(; 
    place=Place(; name="Hotel β",
    width=60,
    height=100,
    smallGridMode=20,
    plotPos=(x = m1.place.plotPos.x,
        y = (m1.place.plotPos.y + m1.place.height + vpad)) 
    ))
    m3 = Marketplace(; μg=(1 / 7), ag=(1 / 24), bg=(9 / 24),
    place=Place(; name="Mall α",
    width=100,
    height=60,
    plotPos=(x = m1.place.plotPos.x + m1.place.width + hpad,
        y = (m1.place.plotPos.y)) 
    ))
    m4 = Marketplace(; μg=(1 / 2), ag=(0.5 / 24), bg=(2 / 24),
    place=Place(; name="Bakery",
    width=30,
    height=15,
    plotPos=(x = m2.place.plotPos.x + m2.place.width + hpad,
        y = (m2.place.plotPos.y)) 
    ))
    
    local w1, w2, w3, w4, w5
    let w_size = rand(Uniform(60, 80))
        w1 = Workplace(; startTime=rand(Uniform(22/24, 23/24)),
        endTime=rand(Uniform(6 / 24, 7 / 24)),
        eP=rand(Uniform(0.05, 0.1)),
        place=Place(; name="Night Office",
        width=w_size,
        height=w_size,
        plotPos=(x = centralPlace.plotPos.x,
            y = (centralPlace.plotPos.y + centralPlace.height + vpad)) 
        ))
    end
    let w_size = rand(Uniform(90, 95))
        w2 = Workplace(; startTime=rand(Uniform(4 / 24, 11 / 24)),
        endTime=rand(Uniform(16 / 24, 23 / 24)),
        eP=rand(Uniform(0.2, 0.3)),
        place=Place(; name="Office β",
        smallGridMode=0.0,
        width=250,
        height=w_size,
        plotPos=(x = w1.place.plotPos.x + w1.place.width + hpad,
            y = w1.place.plotPos.y) 
        ))
    end
    let w_size = rand(Uniform(40, 50))
        w3 = Workplace(; startTime=rand(Uniform(8 / 24, 9 / 24)),
        endTime=rand(Uniform(14 / 24, 16 / 24)),
        eP=rand(Uniform(0.05, 0.07)),
        place=Place(; name="Office γ",
        smallGridMode = 10,
        width=w_size,
        height=w_size,
        plotPos=(x = w2.place.plotPos.x + w2.place.width + hpad,
            y = w2.place.plotPos.y) 
        ))
    end
    let w_size = rand(Uniform(70, 90))
        w4 = Workplace(; startTime=rand(Uniform(6 / 24, 7.5 / 24)),
        endTime=rand(Uniform(11 / 24, 12 / 24)),
        eP=rand(Uniform(0.04, 0.08)),
        place=Place(; name="Office δ",
        width=w_size,
        height=w_size,
        plotPos=(x = w3.place.plotPos.x + w3.place.width + hpad,
            y = w3.place.plotPos.y) 
        ))
    end
    let w_size = rand(Uniform(50, 60))
        w5 = Workplace(; startTime=rand(Uniform(8 / 24, 11 / 24)),
        endTime=rand(Uniform(13 / 24, 18 / 24)),
        eP=rand(Uniform(0.02, 0.05)),
        place=Place(; name="Office ϵ",
        width=w_size,
        height=w_size,
        plotPos=(x = m4.place.plotPos.x + m4.place.width + hpad,
            y = m4.place.plotPos.y) 
        ))
    end

    markets = [m1,m2,m3,m4]
    if oneMarketMode
        markets = [m3]
    end
    workplaces=[w1,w2,w3,w4,w5]
    if noWork
        workplaces=[]
    end

    model_fn(args...; kwargs...,
    centralPlace,
    marketplaces=markets
    ,workplaces=workplaces,
    modelNameAppend=", $(@currentFuncName)"
    )
end
## Models
model1(μ=1/50 ; kwargs...) = execModel(; kwargs..., model=CoronaModel(; name="m1_1", μ,nextSickness=nextSicknessExp))

function nsP1_2(model::CoronaModel, person::Person)::Float64
    @match getStatus(person) begin
        Recovered ||
        Healthy =>
        rand(Exponential(inv(model.μ)))
        _ =>
        -1.0
    end
end
m1_2(μ=0.1 ; n=10^3, kwargs...) = execModel(; n, kwargs..., model=CoronaModel(; name="m1_2",μ,nextSickness=nsP1_2))
###
function nsP2_g(model::CoronaModel, person::Person, infectors, infectables)::Float64
    if ! (getStatus(person) in infectables)
        return -1
    end
    count_sick = count(model.centralPlace.people) do p p.status in infectors end
    if count_sick == 0
        return -1
    end
    rd = Exponential(inv(model.μ * count_sick))
    rand(rd)
end
nsP2_1_1(model::CoronaModel, person::Person) = nsP2_g(model, person, (Sick,), (Healthy,))
nsP2_1_2(model::CoronaModel, person::Person) = nsP2_g(model, person, (Sick,), (Healthy, Recovered))
nsP2_2_1(model::CoronaModel, person::Person) = nsP2_g(model, person, (Sick, RecoveredRemission), (Healthy,))
nsP2_2_2(model::CoronaModel, person::Person) = nsP2_g(model, person, (Sick, RecoveredRemission), (Healthy, Recovered))

m2_1_1(μ=1 / 10^2 ; n=10^3, kwargs...) = execModel(; n, kwargs..., model=CoronaModel(; name="$(@currentFuncName)¦ n=$n, μ=$(μ)", μ, nextSickness=nsP2_1_1))
m2_1_2(μ=1 / 10^2 ; n=10^3, kwargs...) = execModel(; n, kwargs..., model=CoronaModel(; name="$(@currentFuncName)¦ n=$n, μ=$(μ)", μ, nextSickness=nsP2_1_2))
m2_2_1(μ=1 / 10^2 ; n=10^3, kwargs...) = execModel(; n, kwargs..., model=CoronaModel(; name="$(@currentFuncName)¦ n=$n, μ=$(μ)", μ, nextSickness=nsP2_2_1))
m2_2_2(μ=1 / 10^2 ; n=10^3, kwargs...) = execModel(; n, kwargs..., model=CoronaModel(; name="$(@currentFuncName)¦ n=$n, μ=$(μ)", μ, nextSickness=nsP2_2_2))
###
function getSMG(person::Person)
    if person.currentPlace.smallGridMode > 0
        return (ceil(Int, (person.pos.x / person.currentPlace.smallGridMode)), ceil(Int, (person.pos.y / person.currentPlace.smallGridMode)))
    else
        return (0, 0)
    end
end
function distance(a::Person, b::Person)::Float64
    if (a.isIsolated || b.isIsolated) || (getSMG(a) ≠ getSMG(b))
        return Inf
    else
        return √((a.pos.x - b.pos.x)^2 + (a.pos.y - b.pos.y)^2)
    end
end
function δdc(d::Float64, c::Number)::Int64
    if d < c
        1
    else
    0
    end
end
function f_ij2(model::CoronaModel, a::Person, b::Person, c)::Float64
    d = distance(a, b)
    res = δdc(d, c) * (model.μ / (1 + d))
    return res
end

function m3_g(μ=1 / 10^1 ; n=10^3, discrete_opt=1.0, c=30, isolationProbability=0.0,infectors, infectables, f_ij=f_ij2, centralPlace=nothing, marketplaces=[], workplaces=[], modelNameAppend="", smallGridMode=0.0, kwargs...)
    function nsP3_g(model::CoronaModel, person::Person)::Float64
        if ! (getStatus(person) in infectables)
            return -1
        end
        totalRate = 0
        for neighbor in person.currentPlace.people
            if ! (neighbor.status in infectors)
            continue
            end
            totalRate += f_ij(model, person, neighbor, c)
        end
        if totalRate <= 0
            return -1
        end
        if totalRate == Inf
            @warn "Infinite rate observed!"
            return 0
        end
        rd = Exponential(inv(totalRate))
        return rand(rd)
    end

    model = CoronaModel(; name="$(@currentFuncName)¦ infectors=$infectors, infectables=$infectables, c=$(c)$modelNameAppend", discrete_opt, μ, nextSickness=nsP3_g, isolationProbability, centralPlace, marketplaces, workplaces, smallGridMode)

    execModel(; n, kwargs..., model)
end
m3_1_1(args... ; kwargs...) = m3_g(args... ; kwargs..., infectors=(Sick,), infectables=(Healthy,))
m3_1_2(args... ; kwargs...) = m3_g(args... ; kwargs..., infectors=(Sick,), infectables=(Healthy, Recovered))
m3_2_1(args... ; kwargs...) = m3_g(args... ; kwargs..., infectors=(Sick, RecoveredRemission), infectables=(Healthy,))
m3_2_2(args... ; kwargs...) = m3_g(args... ; kwargs..., infectors=(Sick, RecoveredRemission), infectables=(Healthy, Recovered))
##
m5() = withMW(m3_2_2,0.2; discrete_opt=1//24, visualize=true, c=500, initialPeople=gp_H_dV, isolationProbability=0.3, smallGridMode=80, daysInSec=1//4)
##
# The End
##
# BUG: https://github.com/julia-vscode/julia-vscode/issues/1600
# Better workaround: Choose the module from the bottom right of vscode manually.
# Bad workaround: Use `@force using .SIR.SIR`
# for n in names(@__MODULE__; all=true)
#     if Base.isidentifier(n) && n ∉ (Symbol(@__MODULE__), :eval, :include)
#         # @labeled n 
#         # @labeled
#         @eval export $n
#     end
# end
##

##
# end

# using ForceImport
# @force using .SIR