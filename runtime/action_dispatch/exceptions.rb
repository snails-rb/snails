# Exception classes of the request layer, named by `rescue_from` clauses.
# Nothing in the runtime raises them: remote-IP spoof detection and Accept
# MIME validation are middleware work the emitted dispatcher does not do.
# They exist so a rescue clause's class list resolves; an undefined name there
# turns every other error the action raises into a NameError that hides it.
module ActionDispatch
  module RemoteIp
    class IpSpoofAttackError < StandardError
    end
  end

  module Http
    module MimeNegotiation
      class InvalidType < StandardError
      end
    end
  end
end
