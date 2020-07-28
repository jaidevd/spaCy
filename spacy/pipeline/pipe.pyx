# cython: infer_types=True, profile=True, binding=True
import srsly

from ..tokens.doc cimport Doc

from ..util import link_vectors_to_models, create_default_optimizer
from ..errors import Errors
from .. import util


class Pipe:
    """This class is a base class and not instantiated directly. Trainable
    pipeline components like the EntityRecognizer or TextCategorizer inherit
    from it and it defines the interface that components should follow to
    function as trainable components in a spaCy pipeline.

    DOCS: https://spacy.io/api/pipe
    """

    name = None

    def __init__(self, vocab, model, name, **cfg):
        """Initialize a pipeline component.

        vocab (Vocab): The shared vocabulary.
        model (thinc.api.Model): The Thinc Model powering the pipeline component.
        name (str): The component instance name.
        **cfg: Additonal settings and config parameters.

        DOCS: https://spacy.io/api/pipe#init
        """
        raise NotImplementedError

    def __call__(self, Doc doc):
        """Add context-sensitive embeddings to the Doc.tensor attribute.

        docs (Doc): The Doc to preocess.
        RETURNS (Doc): The processed Doc.

        DOCS: https://spacy.io/api/pipe#call
        """
        scores = self.predict([doc])
        self.set_annotations([doc], scores)
        return doc

    def pipe(self, stream, *, batch_size=128):
        """Apply the pipe to a stream of documents. This usually happens under
        the hood when the nlp object is called on a text and all components are
        applied to the Doc.

        stream (Iterable[Doc]): A stream of documents.
        batch_size (int): The number of documents to buffer.
        YIELDS (Doc): Processed documents in order.

        DOCS: https://spacy.io/api/pipe#pipe
        """
        for docs in util.minibatch(stream, size=batch_size):
            scores = self.predict(docs)
            self.set_annotations(docs, scores)
            yield from docs

    def predict(self, docs):
        """Apply the pipeline's model to a batch of docs, without modifying them.
        Returns a single tensor for a batch of documents.

        docs (Iterable[Doc]): The documents to predict.
        RETURNS: Vector representations for each token in the documents.

        DOCS: https://spacy.io/api/pipe#predict
        """
        raise NotImplementedError

    def set_annotations(self, docs, scores):
        """Modify a batch of documents, using pre-computed scores.

        docs (Iterable[Doc]): The documents to modify.
        tokvecses: The tensors to set, produced by Pipe.predict.

        DOCS: https://spacy.io/api/pipe#predict
        """
        raise NotImplementedError

    def rehearse(self, examples, *, sgd=None, losses=None, **config):
        """Perform a "rehearsal" update from a batch of data. Rehearsal updates
        teach the current model to make predictions similar to an initial model,
        to try to address the "catastrophic forgetting" problem. This feature is
        experimental.

        examples (Iterable[Example]): A batch of Example objects.
        drop (float): The dropout rate.
        sgd (thinc.api.Optimizer): The optimizer.
        losses (Dict[str, float]): Optional record of the loss during training.
            Updated using the component name as the key.
        RETURNS (Dict[str, float]): The updated losses dictionary.

        DOCS: https://spacy.io/api/pipe#rehearse
        """
        pass

    def get_loss(self, examples, scores):
        """Find the loss and gradient of loss for the batch of documents and
        their predicted scores.

        examples (Iterable[Examples]): The batch of examples.
        scores: Scores representing the model's predictions.
        RETUTNRS (Tuple[float, float]): The loss and the gradient.

        DOCS: https://spacy.io/api/pipe#get_loss
        """
        raise NotImplementedError

    def add_label(self, label):
        """Add an output label, to be predicted by the model. It's possible to
        extend pretrained models with new labels, but care should be taken to
        avoid the "catastrophic forgetting" problem.

        label (str): The label to add.
        RETURNS (int): 0 if label is already present, otherwise 1.

        DOCS: https://spacy.io/api/pipe#add_label
        """
        raise NotImplementedError

    def create_optimizer(self):
        """Create an optimizer for the pipeline component.

        RETURNS (thinc.api.Optimizer): The optimizer.

        DOCS: https://spacy.io/api/pipe#create_optimizer
        """
        return create_default_optimizer()

    def begin_training(self, get_examples=lambda: [], *, pipeline=None, sgd=None):
        """Initialize the pipe for training, using data examples if available.

        get_examples (Callable[[], Iterable[Example]]): Optional function that
            returns gold-standard Example objects.
        pipeline (List[Tuple[str, Callable]]): Optional list of pipeline
            components that this component is part of. Corresponds to
            nlp.pipeline.
        sgd (thinc.api.Optimizer): Optional optimizer. Will be created with
            create_optimizer if it doesn't exist.
        RETURNS (thinc.api.Optimizer): The optimizer.

        DOCS: https://spacy.io/api/pipe#begin_training
        """
        self.model.initialize()
        if hasattr(self, "vocab"):
            link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    def set_output(self, nO):
        # TODO: document this across components?
        if self.model.has_dim("nO") is not False:
            self.model.set_dim("nO", nO)
        if self.model.has_ref("output_layer"):
            self.model.get_ref("output_layer").set_dim("nO", nO)

    def get_gradients(self):
        """Get non-zero gradients of the model's parameters, as a dictionary
        keyed by the parameter ID. The values are (weights, gradients) tuples.
        """
        # TODO: How is this used?
        gradients = {}
        queue = [self.model]
        seen = set()
        for node in queue:
            if node.id in seen:
                continue
            seen.add(node.id)
            if hasattr(node, "_mem") and node._mem.gradient.any():
                gradients[node.id] = [node._mem.weights, node._mem.gradient]
            if hasattr(node, "_layers"):
                queue.extend(node._layers)
        return gradients

    def use_params(self, params):
        """Modify the pipe's model, to use the given parameter values. At the
        end of the context, the original parameters are restored.

        params (dict): The parameter values to use in the model.

        DOCS: https://spacy.io/api/pipe#use_params
        """
        with self.model.use_params(params):
            yield

    def score(self, examples, **kwargs):
        """Score a batch of examples.

        examples (Iterable[Example]): The examples to score.
        RETURNS (Dict[str, Any]): The scores.

        DOCS: https://spacy.io/api/pipe#score
        """
        return {}

    def to_bytes(self, exclude=tuple()):
        """Serialize the pipe to a bytestring.

        exclude (Iterable[str]): String names of serialization fields to exclude.
        RETURNS (bytes): The serialized object.

        DOCS: https://spacy.io/api/pipe#to_bytes
        """
        serialize = {}
        serialize["cfg"] = lambda: srsly.json_dumps(self.cfg)
        serialize["model"] = self.model.to_bytes
        if hasattr(self, "vocab"):
            serialize["vocab"] = self.vocab.to_bytes
        return util.to_bytes(serialize, exclude)

    def from_bytes(self, bytes_data, exclude=tuple()):
        """Load the pipe from a bytestring.

        exclude (Iterable[str]): String names of serialization fields to exclude.
        RETURNS (Pipe): The loaded object.

        DOCS: https://spacy.io/api/pipe#from_bytes
        """

        def load_model(b):
            try:
                self.model.from_bytes(b)
            except AttributeError:
                raise ValueError(Errors.E149)

        deserialize = {}
        if hasattr(self, "vocab"):
            deserialize["vocab"] = lambda b: self.vocab.from_bytes(b)
        deserialize["cfg"] = lambda b: self.cfg.update(srsly.json_loads(b))
        deserialize["model"] = load_model
        util.from_bytes(bytes_data, deserialize, exclude)
        return self

    def to_disk(self, path, exclude=tuple()):
        """Serialize the pipe to disk.

        path (str / Path): Path to a directory.
        exclude (Iterable[str]): String names of serialization fields to exclude.

        DOCS: https://spacy.io/api/pipe#to_disk
        """
        serialize = {}
        serialize["cfg"] = lambda p: srsly.write_json(p, self.cfg)
        serialize["vocab"] = lambda p: self.vocab.to_disk(p)
        serialize["model"] = lambda p: self.model.to_disk(p)
        util.to_disk(path, serialize, exclude)

    def from_disk(self, path, exclude=tuple()):
        """Load the pipe from disk.

        path (str / Path): Path to a directory.
        exclude (Iterable[str]): String names of serialization fields to exclude.
        RETURNS (Pipe): The loaded object.

        DOCS: https://spacy.io/api/pipe#from_disk
        """

        def load_model(p):
            try:
                self.model.from_bytes(p.open("rb").read())
            except AttributeError:
                raise ValueError(Errors.E149)

        deserialize = {}
        deserialize["vocab"] = lambda p: self.vocab.from_disk(p)
        deserialize["cfg"] = lambda p: self.cfg.update(deserialize_config(p))
        deserialize["model"] = load_model
        util.from_disk(path, deserialize, exclude)
        return self


def deserialize_config(path):
    if path.exists():
        return srsly.read_json(path)
    else:
        return {}