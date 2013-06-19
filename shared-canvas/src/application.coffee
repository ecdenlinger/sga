# # Application

SGAReader.namespace "Application", (Application) ->
  #
  # ## Application.SharedCanvas
  #
  Application.namespace "SharedCanvas", (SharedCanvas) ->
    SharedCanvas.initInstance = (args...) ->
      MITHgrid.Application.initInstance "SGA.Reader.Application.SharedCanvas", args..., (that) ->
        options = that.options

        #
        # ### Presentation Coordination
        #

        presentations = []

        # This is a convenience method for creating a Shared Canvas
        # presentation and tying it to the data management application.
        # All presentations linked to this application will be coordinated
        # when the current sequence or canvas changes.
        #
        that.addPresentation = (config) ->
          p = SGA.Reader.Presentation.Canvas.initInstance config.container,
            types: config.types
            application: -> that
            dataView: that.dataView.canvasAnnotations
          presentations.push [ p, config.container ]

        #
        # When we change the sequence, we find out where our current
        # canvas is in the new sequence and set the position to reflect
        # the new relationship between the canvas and the current sequence.
        #
        currentSequence = null

        that.events.onSequenceChange.addListener (s) ->
          currentSequence = s
          seq = that.dataStore.data.getItem currentSequence
          p = 0
          if seq?.sequence?
            p = seq.sequence.indexOf that.getCanvas()
          p = 0 if p < 0
          that.setPosition p
            
        #
        # The position lets us manage our path through a sequence without
        # having to know the names of the canvases.
        #
        that.events.onPositionChange.addListener (p) ->
          seq = that.dataStore.data.getItem currentSequence
          canvasKey = seq.sequence?[p]
          that.setCanvas canvasKey

        #
        # But if we do know the name of the canvas we want to see, we
        # can switch to it and everything else will be kept in sync as
        # long as the canvas is in the current sequence.
        #
        that.events.onCanvasChange.addListener (k) ->
          that.dataView.canvasAnnotations.setKey k
          seq = that.dataStore.data.getItem currentSequence
          p = seq.sequence.indexOf k
          if p >= 0 && p != that.getPosition()
            that.setPosition p
          pp[0].setCanvas k for pp in presentations
          k

        #
        # ### Manifest Import
        #

        #
        # manifestData holds the data read from the shared canvas
        # manifest that we then process into the application's data store.
        #
        manifestData = SGA.Reader.Data.Manifest.initInstance()

        #
        # We expose several of the manifestData methods so that things like
        # the progress bar can know where we are in the process.
        #
        that.events.onItemsProcessedChange = manifestData.events.onItemsProcessedChange
        that.events.onItemsToProcessChange = manifestData.events.onItemsToProcessChange
        that.getItemsProcessed = manifestData.getItemsProcessed
        that.getItemsToProcess = manifestData.getItemsToProcess
        that.setItemsProcessed = manifestData.setItemsProcessed
        that.setItemsToProcess = manifestData.setItemsToProcess
        that.addItemsProcessed = manifestData.addItemsProcessed
        that.addItemsToProcess = manifestData.addItemsToProcess

        #
        # textSource manages fetching and storing all of the TEI
        # files that we will be referencing in our text content
        # annotations.
        #
        textSource = SGA.Reader.Data.TextStore.initInstance()

        that.withSource = textSource.withFile

        extractSpatialConstraint = (item, id) ->
          return unless id?
          constraint = manifestData.getItem id
          if 'oaFragmentSelector' in constraint.type
            if constraint.rdfvalue[0].substr(0,5) == "xywh="
              item.shape = "Rectangle"
              bits = constraint.rdfvalue[0].substr(5).split(",")
              item.x = parseInt(bits[0],10)
              item.y = parseInt(bits[1],10)
              item.width = parseInt(bits[2],10)
              item.height = parseInt(bits[3],10)
          else
            if constraint.oaxbegin?
              item.start = parseInt(constraint.oaxbegin?[0], 10)
            if constraint.oaxend?
              item.end = parseInt(constraint.oaxend?[0], 10)
          # handle SVG constraints (rectangles, ellipses)
          # handle time constraints? for video/sound annotations?

        extractTextTarget = (item, id) ->
          return unless id?
          target = manifestData.getItem id
          if "oaSpecificResource" in target.type
            item.target = target.oahasSource
            if target.oahasStyle?
              styleItem = manifestData.getItem target.oahasStyle[0]
              if "text/css" in styleItem.dcformat
                item.css = styleItem.cntchars

            extractSpatialConstraint(item, target.oahasSelector?[0])
          else
            item.target = id

        extractTextBody = (item, id) ->
          return unless id?
          body = manifestData.getItem id
          textSource.addFile(body.oahasSource)
          item.source = body.oahasSource
          extractSpatialConstraint(item, body.oahasSelector?[0])

        pullData = ->
          # now pull data out into data store
          # if multiple sequences, we want to add a control to allow
          # selection
          items = []
          syncer = MITHgrid.initSynchronizer()

          canvases = manifestData.getCanvases()
          that.addItemsToProcess canvases.length
          syncer.process canvases, (id) ->
            that.addItemsProcessed 1
            mitem = manifestData.getItem id
            items.push
              id: id
              type: 'Canvas'
              width: parseInt(mitem.exifwidth?[0], 10)
              height: parseInt(mitem.exifheight?[0], 10)
              label: mitem.dctitle || mitem.rdfslabel

          zones = manifestData.getZones()
          that.addItemsToProcess zones.length
          syncer.process zones, (id) ->
            that.addItemsProcessed 1
            zitem = manifestData.getItem id
            items.push
              id: id
              type: 'Zone'
              width: parseInt(mitem.exifwidth?[0], 10)
              height: parseInt(mitem.exifheight?[0], 10)
              angle: parseInt(mitem.scnaturalAngle?[0], 10) || 0
              label: zitem.rdfslabel

          seq = manifestData.getSequences()          
          that.addItemsToProcess seq.length
          syncer.process seq, (id) ->
            that.addItemsProcessed 1
            sitem = manifestData.getItem id
            item =
              id: id
              type: 'Sequence'
              label: sitem.rdfslabel

            # walk list of canvases
            seq = []
            seq.push sitem.rdffirst[0]
            sitem = manifestData.getItem sitem.rdfrest[0]
            while sitem.id? # manifestData.contains(sitem.rdfrest?[0])
              seq.push sitem.rdffirst[0]
              sitem = manifestData.getItem sitem.rdfrest[0]
            item.sequence = seq
            items.push item

          textSources = {}
          textAnnos = []

          # now get the annotations we know something about handling
          annos = manifestData.getAnnotations()          
          that.addItemsToProcess annos.length
          syncer.process annos, (id) ->
            #
            # Once we have our various annotations, we want to process
            # them to produce sets of items that can be displayed in a
            # sequence - move some of the logic from the presentation to
            # here so we are only concerned with presenting things.
            #
            that.addItemsProcessed 1
            aitem = manifestData.getItem id            
            array = null
            item =
              id: id

            # for now, we *assume* that the content annotation is coming
            # from a TEI file and is marked by begin/end pointers
            if "scContentAnnotation" in aitem.type
              extractTextTarget item, aitem.oahasTarget?[0]
              extractTextBody   item, aitem.oahasBody?[0]
              textSources[item.source] ?= []
              textSources[item.source].push [ id, item.start, item.end ]
              item.type = "TextContentZone"
              array = items

            else if "scImageAnnotation" in aitem.type
              imgitem = manifestData.getItem aitem.oahasBody
              imgitem = imgitem[0] if $.isArray(imgitem)
              array = items

              item.target = aitem.oahasTarget
              item.label = aitem.rdfslabel
              item.image = imgitem.oahasSource || aitem.oahasBody
              item.type = "Image"
              if "image/jp2" in imgitem["dcformat"] and that.imageControls?
                item.type = "ImageViewer"
              #item.format = imgitem["dcformat"]

            else if "scZoneAnnotation" in aitem.type
              target = manifestData.getItem aitem.oahasTarget
              extractSpatialConstraint item, target.hasSelector?[0]
              array = items

              item.target = target.hasSource
              item.label = aitem.rdfslabel
              item.type = "ZoneAnnotation"

            else
              #
              # All of the SGA-specific annotations will have types
              # prefixed with "sga" and ending in "Annotation"
              sgaTypes = (f.substr(3) for f in aitem.type when f.substr(0,3) == "sga" and f.substr(f.length-10) == "Annotation")
              if sgaTypes.length > 0
                extractTextTarget item, aitem.oahasTarget?[0]
                item.type = sgaTypes
                array = textAnnos

            array.push item if item.type? and array?

          syncer.done ->
            # We process the highlight annotations here so we don't have
            # to do it *every* time we show a canvas.
            # each addition, deletion, etc., targets a scContentAnnotation
            # but we want to make sure we get any scContentAnnotation text
            # that isn't covered by any of the other annotations
            
            that.addItemsToProcess 1 + textAnnos.length
            that.dataStore.data.loadItems items, -> 
              items = []
              modstart = {}
              modend = {}
              modInfo = {}
              setMod = (item) ->
                source = item.target
                start = item.start
                end = item.end
                id = item.id
                id = id[0] if $.isArray(id)
                modInfo[id] = item
                modstart[source] ?= {}
                modstart[source][start] ?= []
                modstart[source][start].push id
                modend[source] ?= {}
                modend[source][end] ?= []
                modend[source][end].push id

              setMod item for item in textAnnos

              sources = (s for s of modstart)
              that.addItemsToProcess sources.length
              that.addItemsProcessed textAnnos.length

              for source in sources
                do (source) ->
                  that.withSource source, (text) ->
                    textItems = []
                    modIds = [ ]
                    br_pushed = false

                    pushTextItem = (classes, css, target, start, end) ->
                      textItems.push
                        type: classes
                        css: css.join(" ")
                        text: text[start ... end]
                        id: source + "-" + start + "-" + end
                        target: target
                        start: start
                        end: end
                    
                    processNode = (start, end) ->
                      classes = []
                      css = []
                      for id in modIds
                        classes.push modInfo[id].type
                        if $.isArray(modInfo[id].css)
                          css.push modInfo[id].css.join(" ")
                        else
                          css.push modInfo[id].css

                      classes.push "Text" if classes.length == 0

                      makeTextItems start, end, classes, css

                    #
                    # We run through each possible shared canvas
                    # target that might be mapped onto the source TEI
                    # via the TextContent annotation. We want to target
                    # the shared canvas text content zone, not the
                    # text source that the highlight is targeting in the
                    # actual open annotation model.
                    #
                    makeTextItems = (start, end, classes, css) ->
                      for candidate in (textSources[source] || [])
                        if start <= candidate[2] and end >= candidate[1]
                          s = Math.min(Math.max(start, candidate[1]),candidate[2])
                          e = Math.max(Math.min(end, candidate[2]), candidate[1])
                          pushTextItem classes, css, candidate[0], s, e
                      false

                    #
                    # A line break is just a zero-width annotation at
                    # the given position.
                    #
                    makeLinebreak = (pos) ->
                      classes = [ "LineBreak" ]
                      #classes.push modInfo[id].type for id in modIds
                      makeTextItems pos, pos, classes, [ "" ]

                    #
                    mstarts = modstart[source] || []
                    mends = modend[source] || []
                    last_pos = 0
                    positions = (parseInt(p,10) for p of mstarts).concat(parseInt(p,10) for p of mends).sort (a,b) -> a-b
                    for pos in positions
                      if pos != last_pos
                        processNode last_pos, pos
                        if br_pushed and !text.substr(last_pos, pos - last_pos).match(/^\s*$/)
                          br_pushed = false
                        needs_br = false
                        for id in (mstarts[pos] || [])
                          if "LineAnnotation" in modInfo[id].type
                            needs_br = true
                          modIds.push id
                        for id in (mends[pos] || [])
                          if "LineAnnotation" in modInfo[id].type
                            needs_br = true
                          idx = modIds.indexOf id
                          modIds.splice idx, 1 if idx > -1
                        if needs_br and not br_pushed
                          makeLinebreak pos
                          br_pushed = true
                        last_pos = pos
                    processNode last_pos, text.length
                    
                    that.dataStore.data.loadItems textItems, ->
                      that.addItemsProcessed 1
                  
              that.addItemsProcessed 1

        loadManifests = (url) ->
          # Working example:
          # This would work because pull data is done last.
          # We now need to change the way line-framentation is handled in order to support 
          # multiple calls to pullData()
          #
          # manifestData.importFromURL options.url, ->
          #   manifestData.importFromURL "http://localhost:5000/annotate?q=text:feelings", ->
          #     pullData()
          if url.length > 1
            manifestData.importFromURL url[0], ->
              loadManifests(url[1..url.length])
          else
            manifestData.importFromURL url[0], pullData

        # Expose loadManifests to allow an application to load more annotations
        that.loadManifests = loadManifests

        if options.url?
          #
          # If we're given a URL in our options, then go ahead and load
          # it. For now, this is the only way to get data from a manifest.
          #
          loadManifests [options.url]
    #
    # ### Application.SharedCanvas#builder
    #
    # This is an alternate instantiation method that will look through the
    # DOM and find elements with the given class and instantiate
    # Application.SharedCanvas applications for each manifest found along
    # with Presentation.Canvas presentations for each element.
    #
    # Options:
    #
    # * class - the CSS class of the elements (defaults to "canvas")
    # * progressTracker - a component with the setNumerator and
    #   setDenominator methods that can show progress to the user
    #
    SharedCanvas.builder = (config) ->
      that =
        manifests: {}

      manifestCallbacks = {}

      # Initialize these to nil functions in case we don't have a progress
      # tracker. Also makes sure that CoffeeScript scopes them correctly.
      updateProgressTracker = ->
      updateProgressTrackerVisibility = ->

      if config.progressTracker?
        updateProgressTracker = ->
          # Go through and calculate all of the unfinished items. Then
          # update the progress tracker. Should work even if a builder
          # is tracking multiple manifests.
          n = 0
          d = 0
          for m, obj of that.manifests
            n += obj.getItemsProcessed()
            d += obj.getItemsToProcess()
          config.progressTracker.setNumerator(n)
          config.progressTracker.setDenominator(d or 1)

        uptv = null
        uptvTimer = 1000

        updateProgressTrackerVisibility = ->
          if uptv?
            uptvTimer = 500
          else
            uptv = ->
              for m, obj of that.manifests
                if obj.getItemsToProcess() > obj.getItemsProcessed()
                  config.progressTracker.show()
                  uptvTimer /= 2
                  uptvTimer = 500 if uptvTimer < 500
                  setTimeout uptv, uptvTimer
                  return
              config.progressTracker.hide() if uptvTimer > 500
              uptvTimer *= 2
              uptvTimer = 10000 if uptvTimer > 10000
              setTimeout uptv, uptvTimer
            uptv()

      #
      # #### #onManifest
      #
      # * url: manifest URL
      # * cb: callback to call when the manifest is loaded and ready
      #
      # This function accepts a callback function that will be called
      # when the manifest has been loaded and processed. The callback will
      # receive one argument representing the Application.SharedCanvas
      # instance associated with the manifest URL.
      #
      that.onManifest = (url, cb) ->
        if that.manifests[url]?
          that.manifests[url].ready ->
            cb that.manifests[url]
        else
          manifestCallbacks[url] ?= []
          manifestCallbacks[url].push cb

      #
      # #### #addPresentation
      #
      # * el: the DOM element to contain the shared canvas presentation
      #
      # The element should have the following data- attributes:
      #
      # * data-manifest: the URL of the manifest
      # * data-types: a comma-separated list of annotation types to render
      #
      # The data types can be any of the following:
      #
      # * Image: render any image annotations
      # * Text: render any text annotations
      #
      # N.B.: non-text and non-image annotations will still render. For example,
      # zones will render regardless of the types. Zones inherit the types,
      # so zones in a Text-only rendering will only render text annotations.
      #
      that.addPresentation = (el) ->
        manifestUrl = $(el).data('manifest')
        if manifestUrl?
          manifest = that.manifests[manifestUrl]
          if !manifest?
            manifest = Application.SharedCanvas.initInstance
              url: manifestUrl
            that.manifests[manifestUrl] = manifest
            manifest.ready -> 
              cbs = manifestCallbacks[manifestUrl] || []
              cb(manifest) for cb in cbs
              delete manifestCallbacks[manifestUrl]
            manifest.events.onItemsToProcessChange.addListener updateProgressTracker
            manifest.events.onItemsProcessedChange.addListener updateProgressTracker
            updateProgressTrackerVisibility()
              
          manifest.run()
          types = $(el).data('types')?.split(/\s*,\s*/)
          that.onManifest manifestUrl, (manifest) ->
            manifest.addPresentation
              types: types
              container: $(el)
        
      #
      # Now we go through and find all of the DOM elements that should be
      # made into shared canvas presentations.
      #
      config.class ?= ".canvas"
      $(config.class).each (idx, el) -> that.addPresentation el
      that