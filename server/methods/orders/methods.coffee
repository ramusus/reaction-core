Meteor.methods
  ###
  # Adds tracking information to order
  # Call after any tracking code is generated
  ###
  addTracking: (orderId, tracking, variantId) ->
    check orderId, String #at least make sure it's an ID and not a sneaky selector
    return Orders.update(orderId, {$set: {"shipping.shipmentMethod.tracking":tracking}})

  ###
  # Save supplied order workflow state
  ###
  updateWorkflow: (orderId, currentState) ->
    check orderId, String #at least make sure it's an ID and not a sneaky selector
    Orders.update(orderId, {$set: {"state":currentState}})
    return Meteor.call "updateHistory", orderId, currentState
  ###
  # Add files/documents to order
  # use for packing slips, labels, customs docs, etc
  ###
  updateDocuments: (orderId, docId, docType) ->
    check orderId, String #at least make sure it's an ID and not a sneaky selector
    return Orders.update orderId,
      $addToSet:
        "documents":
          docId: docId
          docType: docType
  ###
  # Add to order event history
  ###
  updateHistory: (orderId, event, value) ->
    check orderId, String #at least make sure it's an ID and not a sneaky selector
    return Orders.update orderId,
      $addToSet:
        "history":
          event: event
          value: value
          userId: Meteor.userId()
          updatedAt: new Date()
  ###
  # Finalize any payment where mode is "authorize"
  # and status is "approved", reprocess as "sale"
  ###
  processPayments: (orderId) ->
    check orderId, String #at least make sure it's an ID and not a sneaky selector
    order = Orders.findOne(orderId)
    for paymentMethod,index in order.payment.paymentMethod
      if paymentMethod.mode is 'authorize' and paymentMethod.status is 'approved'
        Meteor[paymentMethod.processor].capture paymentMethod.transactionId, paymentMethod.amount, (error,result) ->
          if result.capture?
            transactionId = paymentMethod.transactionId
            Orders.update { "_id": orderId, "payment.paymentMethod.transactionId": transactionId},
              $set: {
                "payment.paymentMethod.$.transactionId": result.capture.id
                "payment.paymentMethod.$.mode": "capture"
                "payment.paymentMethod.$.status": "completed"
              }
          return
    return

  ###
  # Creates a pdf doc and attaches to order
  # for any existing site url (completed orders)
  ###
  createPDF: (url, orderId, token) ->
    check url, String
    check orderId, String
    check token, String
    @unblock()
    phantomServer = Npm.require "phantomjs"
    phantom = Npm.require 'node-phantom'
    Future = Npm.require("fibers/future")
    future = new Future()

    currentUser = @userId

    fileName = "reaction-orders-" + Date.now() + ".pdf"
    filePath = process.env.PWD + "/.fileStorage/" + fileName
    url = "http://" + this.connection.httpHeaders.host + url

    console.log "Creating PDF for #{url}"

    # updateStorage = Meteor.wrapAsync(ReactionCore.Collections.FileStorage.insert(file:data))
    #PDF Formatting
    paperSize =
      format: "Letter"
      orientation: "portrait"
      margin:
        left: "2.5cm"
        right: "2.5cm"
        top: "1cm"
        bottom: "1cm"

    phantom.create (Meteor.bindEnvironment (err, ph) ->
      if err
        throw err
      else
        # Create a new page synchronously
        page = Meteor.wrapAsync(ph.createPage.bind ph)();
        # Set paper size synchronously
        Meteor.wrapAsync(page.set.bind page)("paperSize", paperSize)
        # page.zoomFactor = 1.5
        # Check status
        status = Meteor.wrapAsync(page.open.bind page)(url)
        if status isnt "success"
          ph.exit()
          throw new Error "Unable to access network"

        # Create function that will be called after
        # we have let the page load and retrieved the clipRect
        finish = (err, clipRect) ->
          # Set clip area synchronously
          Meteor.wrapAsync(page.set.bind page)("clipRect", clipRect)
          console.log "clipRect is set to", Meteor.wrapAsync(page.get.bind page)("clipRect")
          # Render the page synchronously
          Meteor.wrapAsync(page.render.bind page)(filePath)
          # We're done with phantom now
          ph.exit()
          # Save the generated PDF file with metadata using CollectionFS
          fileObj = new FS.File(filePath)
          fileObj.owner = currentUser
          fileObj.metadata =
            orderId: orderId
          doc = ReactionCore.Collections.FileStorage.insert fileObj
          # Finally return (from the method) the new document ID
          future.return doc._id
          return

        finish = Meteor.bindEnvironment finish

        dataIsLoaded = ->
          f = new Future()
          page.evaluate (e) ->
            result = {}
            if Meteor?.status?().connected
              Tracker.flush()
              result.subsReady = DDP._allSubscriptionsReady()
            else
              result.subsReady = false

            printArea = document.getElementById('print-area')
            result.clipRect = printArea?.getBoundingClientRect()
            result.userId = Meteor.userId()
            return result
          , (err, result) ->
            f.return (result.clipRect? and result.subsReady and result.userId?.length)
            return
          f.wait()

        dataIsLoaded = Meteor.bindEnvironment dataIsLoaded

        getPrintArea = ->
          return document.getElementById('print-area').getBoundingClientRect()

        # Initiate login on phantom page
        page.evaluate (token) ->
          Meteor.loginWithToken token
          return token
        ,
        (err, token) ->
          console.log "logging in to phantom page with hashed resume token",token
          return
        , token

        # Wait for page and async data to be loaded
        start = new Date().getTime()
        condition = false
        timeout = 20000
        interval = Meteor.setInterval ->
          now = new Date().getTime()
          if now - start < timeout and !condition
            # If not time-out yet and condition not yet fulfilled, run test again
            condition = dataIsLoaded()
          else
            # Stop this interval
            Meteor.clearInterval interval
            # If condition still never true after timeout
            console.log "createPDF timed out waiting for page subscriptions to be ready" if !condition
            # If condition fulfilled, we move on to getting the print area.
            # If we timed out, we'll continue anyway, and hope that it works
            page.evaluate getPrintArea, finish
          return
        , 250 # repeat check every 250ms
        return
    ),
    # Tell phantom.create call where to find phantom binary
    phantomPath: phantomServer.path

    return future.wait()